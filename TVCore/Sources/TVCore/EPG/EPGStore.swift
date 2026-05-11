import Foundation
import GRDB

public actor EPGStore {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.label = "EPGStore"
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        self.dbQueue = queue
        var url = databaseURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try Self.migrate(queue)
    }

    /// Convenience: store at `Library/Caches/epg.sqlite`.
    ///
    /// Documents is read-only on real tvOS devices (Simulator allows writes,
    /// masking this). The EPG is regenerable from Gracenote/XMLTV, so an
    /// OS-initiated Caches purge is recoverable via `defaultStoreRecovering`.
    public static func defaultStore() throws -> EPGStore {
        let dir = URL.cachesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appending(path: "epg.sqlite")
        return try EPGStore(databaseURL: dbURL)
    }

    /// Open the default store. If opening fails (corrupt SQLite, schema mismatch
    /// after a downgrade, etc.), delete the on-disk file and try once more.
    /// Throws only if the second attempt also fails.
    public static func defaultStoreRecovering() throws -> EPGStore {
        do {
            return try defaultStore()
        } catch {
            let dbURL = URL.cachesDirectory.appending(path: "epg.sqlite")
            try? FileManager.default.removeItem(at: dbURL)
            // SQLite WAL mode writes `epg.sqlite-wal` and `epg.sqlite-shm`
            // sidecars (hyphenated, not dotted). Remove them too so the retry
            // sees a clean slate.
            let dir = dbURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir.appending(path: "epg.sqlite-wal"))
            try? FileManager.default.removeItem(at: dir.appending(path: "epg.sqlite-shm"))
            return try defaultStore()
        }
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_program") { db in
            try db.execute(sql: """
                CREATE TABLE program (
                    id TEXT PRIMARY KEY,
                    channelXmltvID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    subtitle TEXT,
                    desc TEXT,
                    start INTEGER NOT NULL,
                    stop INTEGER NOT NULL,
                    categories TEXT NOT NULL DEFAULT '[]',
                    episodeNumber TEXT,
                    isNew BOOLEAN NOT NULL DEFAULT 0,
                    isLive BOOLEAN NOT NULL DEFAULT 0,
                    rating TEXT
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_program_channel_start ON program(channelXmltvID, start)")
            try db.execute(sql: "CREATE INDEX idx_program_start ON program(start)")
        }
        migrator.registerMigration("v2_channel_icon") { db in
            try db.execute(sql: """
                CREATE TABLE channel_icon (
                    xmltvID TEXT PRIMARY KEY,
                    iconURL TEXT NOT NULL,
                    updatedAt INTEGER NOT NULL
                )
            """)
        }
        try migrator.migrate(queue)
    }

    /// Drain an XMLTV event stream into the store. Inserts in 500-row transactions
    /// so a 100k-program ingest doesn't hold one giant write lock.
    public func ingest(_ events: AsyncThrowingStream<XMLTVEvent, Error>) async throws {
        var batch: [Program] = []
        batch.reserveCapacity(500)

        for try await event in events {
            if Task.isCancelled { return }
            switch event {
            case .channel(let id, _, let iconURL):
                if let iconURL, !id.isEmpty {
                    try await upsertChannelIcon(xmltvID: id, url: iconURL)
                }
            case .program(let program):
                batch.append(program)
                if batch.count >= 500 {
                    try await writeBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        if !batch.isEmpty {
            try await writeBatch(batch)
        }
    }

    public func upsertChannelIcon(xmltvID: String, url: URL) async throws {
        let now = Int64(Date.now.timeIntervalSince1970)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO channel_icon (xmltvID, iconURL, updatedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(xmltvID) DO UPDATE SET
                        iconURL = excluded.iconURL,
                        updatedAt = excluded.updatedAt
                """,
                arguments: [xmltvID, url.absoluteString, now]
            )
        }
    }

    public func iconURLs() async throws -> [String: URL] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT xmltvID, iconURL FROM channel_icon")
            
            var out: [String: URL] = [:]
            out.reserveCapacity(rows.count)
            for row in rows {
                let id: String = row["xmltvID"]
                let raw: String = row["iconURL"]
                
                if let url = URL(string: raw) { out[id] = url }
            }
            return out
        }
    }

    private func writeBatch(_ programs: [Program]) async throws {
        try await dbQueue.write { db in
            for program in programs {
                try program.save(db)
            }
        }
    }

    public func programs(
        channelXmltvID: String,
        from: Date,
        to: Date
    ) async throws -> [Program] {
        let fromEpoch = Int64(from.timeIntervalSince1970)
        let toEpoch = Int64(to.timeIntervalSince1970)
        return try await dbQueue.read { db in
            try Program
                .filter(Program.Columns.channelXmltvID == channelXmltvID)
                .filter(Program.Columns.stop > fromEpoch)
                .filter(Program.Columns.start < toEpoch)
                .order(Program.Columns.start)
                .fetchAll(db)
        }
    }

    public func nowPlaying(channelXmltvID: String, at instant: Date = .now) async throws -> Program? {
        let epoch = Int64(instant.timeIntervalSince1970)
        return try await dbQueue.read { db in
            try Program
                .filter(Program.Columns.channelXmltvID == channelXmltvID)
                .filter(Program.Columns.start <= epoch)
                .filter(Program.Columns.stop > epoch)
                .fetchOne(db)
        }
    }

    /// Fetch "what's on now" for many channels in one read. Returns a dictionary
    /// keyed by `channelXmltvID`; channels with no current program are simply
    /// absent from the result. The mini-guide uses this to avoid 50+ separate
    /// actor hops on every open.
    public func nowPlayingBatch(
        channelXmltvIDs: [String],
        at instant: Date = .now
    ) async throws -> [String: Program] {
        guard !channelXmltvIDs.isEmpty else { return [:] }
        let epoch = Int64(instant.timeIntervalSince1970)
        return try await dbQueue.read { db in
            let programs = try Program
                .filter(channelXmltvIDs.contains(Program.Columns.channelXmltvID))
                .filter(Program.Columns.start <= epoch)
                .filter(Program.Columns.stop > epoch)
                .fetchAll(db)
            var out: [String: Program] = [:]
            out.reserveCapacity(programs.count)
            for p in programs { out[p.channelXmltvID] = p }
            return out
        }
    }

    public func purgeOlderThan(_ date: Date) async throws {
        let epoch = Int64(date.timeIntervalSince1970)
        try await dbQueue.write { db in
            _ = try Program
                .filter(Program.Columns.stop < epoch)
                .deleteAll(db)
        }
    }

    // MARK: - Diagnostics

    public struct ChannelStats: Sendable, Hashable {
        public let channelXmltvID: String
        public let programCount: Int
    }

    /// Returns every distinct `channelXmltvID` in the store along with its program
    /// count. Use to debug "no listings" issues by comparing what's stored against
    /// what the channel side is querying.
    public func channelStats() async throws -> [ChannelStats] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT channelXmltvID, COUNT(*) AS n
                FROM program
                GROUP BY channelXmltvID
                ORDER BY n DESC
            """)
            return rows.map { row in
                ChannelStats(channelXmltvID: row["channelXmltvID"], programCount: row["n"])
            }
        }
    }

    public func totalProgramCount() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM program") ?? 0
        }
    }
}
