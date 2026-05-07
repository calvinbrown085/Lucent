import Foundation

public actor GracenoteIngestService {
    private let store: EPGStore
    private let client: GracenoteAPIClient
    private(set) public var lastRefresh: Date?

    public init(store: EPGStore, client: GracenoteAPIClient = GracenoteAPIClient()) {
        self.store = store
        self.client = client
    }

    /// Fetch listings for `hours` from now in 6-hour chunks, ingest each chunk into
    /// the EPG store, and prune programs that ended more than 6h ago. Mirrors the
    /// contract of `EPGService.refresh(from:)` so callers can swap them.
    public func refresh(lineup: GracenoteLineup, hours: Int = 24) async throws {
        let chunkSize = GracenoteAPIClient.chunkHours
        let chunkCount = max(1, Int((Double(hours) / Double(chunkSize)).rounded(.up)))
        let anchor = Date()
        let timezoneOffset = TimeZone.current.secondsFromGMT()

        #if DEBUG
        print("[Lucent][Gracenote] refresh start lineup=\(lineup.lineupID) postal=\(lineup.postalCode) hours=\(hours) chunks=\(chunkCount)")
        #endif
        var totalChannels = 0
        var totalEvents = 0

        for i in 0..<chunkCount {
            try Task.checkCancellation()
            let start = anchor.addingTimeInterval(Double(i * chunkSize) * 3600)
            let response = try await client.fetchChunk(
                startingAt: start,
                timespanHours: chunkSize,
                timeZoneOffsetSeconds: timezoneOffset,
                lineup: lineup
            )
            let chunkChannels = response.channels.count
            let chunkEvents = response.channels.reduce(0) { $0 + ($1.events?.count ?? 0) }
            totalChannels = max(totalChannels, chunkChannels)
            totalEvents += chunkEvents
            #if DEBUG
            let sampleIDs = response.channels.prefix(5).compactMap { Self.channelXmltvID(for: $0) }
            print("[Lucent][Gracenote] chunk \(i + 1)/\(chunkCount) start=\(start) channels=\(chunkChannels) events=\(chunkEvents) sampleKeys=\(sampleIDs)")
            #endif

            let stream = Self.programStream(from: response)
            try await store.ingest(stream)
        }

        #if DEBUG
        print("[Lucent][Gracenote] refresh done channelsSeen=\(totalChannels) eventsSeen=\(totalEvents)")
        #endif
        lastRefresh = .now
        try? await store.purgeOlderThan(.now.addingTimeInterval(-6 * 3600))
    }

    /// Convert a Gracenote grid response into an `XMLTVEvent` stream so it can flow
    /// through the existing `EPGStore.ingest` path unchanged.
    static func programStream(from response: GracenoteGridResponse) -> AsyncThrowingStream<XMLTVEvent, Error> {
        AsyncThrowingStream { continuation in
            for channel in response.channels {
                let xmltvID = channelXmltvID(for: channel)
                guard let xmltvID else { continue }

                if let icon = thumbnailURL(channel.thumbnail) {
                    let names = [channel.callSign, channel.affiliateName]
                        .compactMap { $0?.nilIfEmpty }
                    continuation.yield(.channel(id: xmltvID, displayNames: names, iconURL: icon))
                }

                guard let events = channel.events else { continue }
                for event in events {
                    if let program = makeProgram(channelXmltvID: xmltvID, event: event) {
                        continuation.yield(.program(program))
                    }
                }
            }
            continuation.finish()
        }
    }

    /// Gracenote's `thumbnail` field is a path like `/assets/p10001_h_h15_aa.png`
    /// served by the TMS image CDN. Resolve against the CDN host; pass through any
    /// already-absolute URL unchanged.
    static let thumbnailBaseURL = URL(string: "https://zap2it.tmsimg.com")!

    static func thumbnailURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        return URL(string: trimmed, relativeTo: thumbnailBaseURL)?.absoluteURL
    }

    /// Use the channel number as the join key — it matches HDHR's `GuideNumber`
    /// (e.g. "8.1"), giving us subchannel-accurate program matches. Fall back to
    /// callsign and finally the opaque channelId if no number is present.
    static func channelXmltvID(for channel: GracenoteChannel) -> String? {
        if let no = channel.channelNo?.trimmingCharacters(in: .whitespaces), !no.isEmpty {
            return no
        }
        if let cs = channel.callSign?.trimmingCharacters(in: .whitespaces), !cs.isEmpty {
            return cs.uppercased()
        }
        return channel.channelId
    }

    static func makeProgram(channelXmltvID: String, event: GracenoteEvent) -> Program? {
        guard
            let start = parseDate(event.startTime),
            let stop = parseDate(event.endTime)
        else { return nil }

        let title = event.program?.title ?? ""
        let subtitle = event.program?.episodeTitle?.nilIfEmpty
        let desc = (event.program?.shortDesc ?? event.program?.longDesc)?.nilIfEmpty
        let categories = event.program?.genres?.compactMap { $0.nilIfEmpty } ?? []
        let flags = event.flag?.map { $0.lowercased() } ?? []
        let isNew = flags.contains("new")
        let isLive = flags.contains("live")
        let rating = event.rating?.nilIfEmpty

        let episodeNumber = formatEpisodeNumber(season: event.program?.season, episode: event.program?.episode)
        let stableID = event.programId ?? event.program?.id ?? "\(channelXmltvID):\(Int64(start.timeIntervalSince1970))"

        return Program(
            id: "\(channelXmltvID):\(stableID):\(Int64(start.timeIntervalSince1970))",
            channelXmltvID: channelXmltvID,
            title: title,
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

    static func formatEpisodeNumber(season: String?, episode: String?) -> String? {
        let s = season?.nilIfEmpty
        let e = episode?.nilIfEmpty
        switch (s, e) {
        case (let s?, let e?): return "S\(s)E\(e)"
        case (nil, let e?): return "E\(e)"
        case (let s?, nil): return "S\(s)"
        default: return nil
        }
    }

    /// Gracenote responses use ISO8601 strings. Some omit seconds (`...T22:00Z`)
    /// and some include them (`...T22:00:00Z`); tolerate both, plus fractional seconds.
    static func parseDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        // Compact "yyyy-MM-ddTHH:mmZ" (no seconds) is not a valid ISO8601 form for
        // ISO8601DateFormatter, so fall back to a manual format.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return df.date(from: raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
