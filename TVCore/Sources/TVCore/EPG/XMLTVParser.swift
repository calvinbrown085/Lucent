import Foundation

public enum XMLTVEvent: Sendable {
    case channel(id: String, displayNames: [String], iconURL: URL?)
    case program(Program)
}

public enum XMLTVParserError: Error, Sendable {
    case parseFailed(underlying: String)
    case invalidDate(String)
}

public struct XMLTVParser: Sendable {
    public init() {}

    /// Stream events from XMLTV at a local file URL. Use this when fetching
    /// from the network — download to a temp file with `URLSession.download(from:)`
    /// first to keep peak memory low (XMLParser streams from disk).
    public func parse(contentsOf url: URL) -> AsyncThrowingStream<XMLTVEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let delegate = SAXDelegate(continuation: continuation)
                guard let parser = XMLParser(contentsOf: url) else {
                    continuation.finish(throwing: XMLTVParserError.parseFailed(underlying: "could not open \(url)"))
                    return
                }
                parser.delegate = delegate
                if !parser.parse() {
                    if let err = parser.parserError {
                        continuation.finish(throwing: err)
                    } else if let saxErr = delegate.error {
                        continuation.finish(throwing: saxErr)
                    } else {
                        continuation.finish(throwing: XMLTVParserError.parseFailed(underlying: "unknown"))
                    }
                } else {
                    continuation.finish()
                }
                _ = delegate
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func parse(data: Data) -> AsyncThrowingStream<XMLTVEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let delegate = SAXDelegate(continuation: continuation)
                let parser = XMLParser(data: data)
                parser.delegate = delegate
                if !parser.parse() {
                    if let err = parser.parserError {
                        continuation.finish(throwing: err)
                    } else if let saxErr = delegate.error {
                        continuation.finish(throwing: saxErr)
                    } else {
                        continuation.finish(throwing: XMLTVParserError.parseFailed(underlying: "unknown"))
                    }
                } else {
                    continuation.finish()
                }
                _ = delegate
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class SAXDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<XMLTVEvent, Error>.Continuation
    var error: Error?

    private enum State {
        case idle
        case channel(id: String, displayNames: [String], iconURL: URL?)
        case program(builder: ProgramBuilder)
    }

    private struct ProgramBuilder {
        var channelXmltvID: String
        var start: Date
        var stop: Date
        var title: String?
        var subtitle: String?
        var desc: String?
        var categories: [String] = []
        var episodeNumber: String?
        var isNew: Bool = false
        var isLive: Bool = false
        var rating: String?

        func build() -> Program {
            Program(
                id: "\(channelXmltvID):\(Int64(start.timeIntervalSince1970))",
                channelXmltvID: channelXmltvID,
                title: title ?? "",
                subtitle: subtitle,
                desc: desc,
                start: start,
                stop: stop,
                categories: categories,
                episodeNumber: episodeNumber,
                isNew: isNew,
                isLive: isLive,
                rating: rating
            )
        }
    }

    private var state: State = .idle
    private var characterBuffer: String = ""
    private var collectingForTag: String?

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMddHHmmss Z"
        return df
    }()

    private static func parseDate(_ raw: String) -> Date? {
        // Handles "20260507140000 -0500" and the sometimes-seen "20260507140000" (UTC).
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let d = dateFormatter.date(from: trimmed) { return d }
        let utcFormatter = DateFormatter()
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.dateFormat = "yyyyMMddHHmmss"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        return utcFormatter.date(from: trimmed)
    }

    init(continuation: AsyncThrowingStream<XMLTVEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "channel":
            let id = attributeDict["id"] ?? ""
            state = .channel(id: id, displayNames: [], iconURL: nil)
        case "icon":
            // XMLTV <icon> appears inside <channel> (and inside <programme>, but we
            // only consume channel-level logos). Take the first non-empty src.
            if case .channel(let id, let names, let existing) = state, existing == nil,
               let src = attributeDict["src"]?.trimmingCharacters(in: .whitespaces),
               !src.isEmpty,
               let url = URL(string: src) {
                state = .channel(id: id, displayNames: names, iconURL: url)
            }
        case "programme":
            guard
                let channelID = attributeDict["channel"],
                let startRaw = attributeDict["start"],
                let stopRaw = attributeDict["stop"],
                let start = Self.parseDate(startRaw),
                let stop = Self.parseDate(stopRaw)
            else {
                state = .idle
                return
            }
            state = .program(builder: ProgramBuilder(channelXmltvID: channelID, start: start, stop: stop))
        case "display-name", "title", "sub-title", "desc", "category", "episode-num":
            collectingForTag = elementName
            characterBuffer = ""
        case "new":
            if case .program(var builder) = state {
                builder.isNew = true
                state = .program(builder: builder)
            }
        case "live":
            if case .program(var builder) = state {
                builder.isLive = true
                state = .program(builder: builder)
            }
        case "rating":
            collectingForTag = "rating-value"
            characterBuffer = ""
        case "value":
            if collectingForTag == "rating-value" {
                characterBuffer = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingForTag != nil {
            characterBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "display-name":
            if case .channel(let id, var names, let icon) = state {
                if !trimmed.isEmpty { names.append(trimmed) }
                state = .channel(id: id, displayNames: names, iconURL: icon)
            }
        case "title":
            if case .program(var builder) = state {
                builder.title = trimmed
                state = .program(builder: builder)
            }
        case "sub-title":
            if case .program(var builder) = state {
                builder.subtitle = trimmed.isEmpty ? nil : trimmed
                state = .program(builder: builder)
            }
        case "desc":
            if case .program(var builder) = state {
                builder.desc = trimmed.isEmpty ? nil : trimmed
                state = .program(builder: builder)
            }
        case "category":
            if case .program(var builder) = state, !trimmed.isEmpty {
                builder.categories.append(trimmed)
                state = .program(builder: builder)
            }
        case "episode-num":
            if case .program(var builder) = state {
                builder.episodeNumber = trimmed.isEmpty ? nil : trimmed
                state = .program(builder: builder)
            }
        case "value":
            if collectingForTag == "rating-value" {
                if case .program(var builder) = state, !trimmed.isEmpty {
                    builder.rating = trimmed
                    state = .program(builder: builder)
                }
            }
        case "rating":
            collectingForTag = nil
        case "channel":
            if case .channel(let id, let names, let icon) = state {
                continuation.yield(.channel(id: id, displayNames: names, iconURL: icon))
            }
            state = .idle
        case "programme":
            if case .program(let builder) = state {
                continuation.yield(.program(builder.build()))
            }
            state = .idle
        default:
            break
        }

        if collectingForTag == elementName {
            collectingForTag = nil
            characterBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
