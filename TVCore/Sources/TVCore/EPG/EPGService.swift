import Foundation

public enum EPGServiceError: Error, Sendable {
    case downloadFailed(Int)
}

public actor EPGService {
    private let store: EPGStore
    private let parser = XMLTVParser()
    private let session: URLSession
    private(set) public var lastRefresh: Date?

    public init(store: EPGStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// Download XMLTV from `url`, stream-parse it, and ingest into the store.
    /// Uses `URLSession.download` so we never hold the full payload in memory.
    public func refresh(from url: URL) async throws {
        let (tempURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EPGServiceError.downloadFailed(http.statusCode)
        }

        let stream = parser.parse(contentsOf: tempURL)
        try await store.ingest(stream)
        lastRefresh = .now

        // Drop programs that have already ended more than 6h ago to keep the cache lean.
        try? await store.purgeOlderThan(.now.addingTimeInterval(-6 * 3600))
    }
}
