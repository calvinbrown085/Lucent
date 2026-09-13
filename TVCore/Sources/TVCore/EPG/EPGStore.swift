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
        migrator.registerMigration("v3_program_metadata") { db in
            try db.execute(sql: "ALTER TABLE program ADD COLUMN year INTEGER")
            try db.execute(sql: "ALTER TABLE program ADD COLUMN credits TEXT NOT NULL DEFAULT '[]'")
        }
        migrator.registerMigration("v4_program_fts") { db in
            // External-content FTS5 over `program`. The table has a TEXT primary
            // key, so it is still a rowid table and FTS5 keys off the implicit
            // rowid (the `content_rowid` default). Triggers keep the index in
            // step with every INSERT/UPDATE/DELETE; the trailing `rebuild`
            // indexes rows that were already present before this migration.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE program_fts USING fts5(
                    title, subtitle, desc,
                    content='program',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """)
            try db.execute(sql: """
                CREATE TRIGGER program_fts_ai AFTER INSERT ON program BEGIN
                    INSERT INTO program_fts(rowid, title, subtitle, desc)
                    VALUES (new.rowid, new.title, new.subtitle, new.desc);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER program_fts_ad AFTER DELETE ON program BEGIN
                    INSERT INTO program_fts(program_fts, rowid, title, subtitle, desc)
                    VALUES ('delete', old.rowid, old.title, old.subtitle, old.desc);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER program_fts_au AFTER UPDATE ON program BEGIN
                    INSERT INTO program_fts(program_fts, rowid, title, subtitle, desc)
                    VALUES ('delete', old.rowid, old.title, old.subtitle, old.desc);
                    INSERT INTO program_fts(rowid, title, subtitle, desc)
                    VALUES (new.rowid, new.title, new.subtitle, new.desc);
                END
            """)
            try db.execute(sql: "INSERT INTO program_fts(program_fts) VALUES ('rebuild')")
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

    /// The program that follows what's on now, for many channels in one read:
    /// per channel, the row with the smallest `start` strictly after `instant`.
    /// Channels with nothing scheduled after `instant` are absent.
    public func upNextBatch(
        channelXmltvIDs: [String],
        at instant: Date = .now
    ) async throws -> [String: Program] {
        guard !channelXmltvIDs.isEmpty else { return [:] }
        let epoch = Int64(instant.timeIntervalSince1970)
        let placeholders = databaseQuestionMarks(count: channelXmltvIDs.count)
        let arguments = StatementArguments(channelXmltvIDs) + [epoch]
        return try await dbQueue.read { db in
            let programs = try Program.fetchAll(
                db,
                sql: """
                    SELECT p.*
                    FROM program p
                    JOIN (
                        SELECT channelXmltvID, MIN(start) AS nextStart
                        FROM program
                        WHERE channelXmltvID IN (\(placeholders)) AND start > ?
                        GROUP BY channelXmltvID
                    ) n ON n.channelXmltvID = p.channelXmltvID AND n.nextStart = p.start
                """,
                arguments: arguments
            )
            var out: [String: Program] = [:]
            out.reserveCapacity(programs.count)
            for p in programs where out[p.channelXmltvID] == nil {
                out[p.channelXmltvID] = p
            }
            return out
        }
    }

    // MARK: - Search & discovery

    /// Full-text prefix search over title, subtitle and description.
    ///
    /// The user string is reduced to alphanumeric words, each turned into a
    /// quoted FTS5 prefix token (`"term"*`) and implicitly AND-ed, so operators,
    /// quotes and stray punctuation can't break the query. Only programs that
    /// haven't ended by `from` are returned, ordered by start; repeat airings
    /// (same channel, title and subtitle) collapse to their earliest airing.
    /// An empty or whitespace-only query returns `[]`.
    public func search(_ query: String, from: Date, limit: Int = 100) async throws -> [Program] {
        guard limit > 0, let match = Self.ftsMatchExpression(query) else { return [] }
        let fromEpoch = Int64(from.timeIntervalSince1970)
        // Over-fetch so that collapsing repeat airings still fills `limit`.
        let rawLimit = limit * 8
        return try await dbQueue.read { db in
            let programs = try Program.fetchAll(
                db,
                sql: """
                    SELECT p.*
                    FROM program_fts f
                    JOIN program p ON p.rowid = f.rowid
                    WHERE program_fts MATCH ? AND p.stop > ?
                    ORDER BY p.start ASC, p.channelXmltvID ASC
                    LIMIT ?
                """,
                arguments: [match, fromEpoch, rawLimit]
            )
            return Self.collapseRepeatAirings(programs, limit: limit)
        }
    }

    /// Builds the FTS5 MATCH expression for a user query, or nil when nothing
    /// searchable survives sanitising.
    static func ftsMatchExpression(_ query: String) -> String? {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                String(word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Keep the first (earliest, given start-ordered input) airing of each
    /// channel + title + subtitle combination.
    static func collapseRepeatAirings(_ programs: [Program], limit: Int) -> [Program] {
        struct Key: Hashable {
            let channel: String
            let title: String
            let subtitle: String?
        }
        var seen = Set<Key>()
        var out: [Program] = []
        for p in programs {
            let key = Key(channel: p.channelXmltvID, title: p.title.lowercased(), subtitle: p.subtitle?.lowercased())
            if seen.insert(key).inserted {
                out.append(p)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Other airings of the same title (case-insensitive exact match) on any
    /// channel that overlap `[from, to)`, ordered by start. Pass the id of the
    /// airing the user is looking at as `excludingID` to leave it out.
    public func airings(
        ofTitle title: String,
        excludingID: String?,
        from: Date,
        to: Date,
        limit: Int = 20
    ) async throws -> [Program] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let fromEpoch = Int64(from.timeIntervalSince1970)
        let toEpoch = Int64(to.timeIntervalSince1970)
        return try await dbQueue.read { db in
            var request = Program
                .filter(sql: "title = ? COLLATE NOCASE", arguments: [trimmed])
                .filter(Program.Columns.stop > fromEpoch)
                .filter(Program.Columns.start < toEpoch)
            if let excludingID {
                request = request.filter(Program.Columns.id != excludingID)
            }
            return try request
                .order(Program.Columns.start, Program.Columns.channelXmltvID)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Programs overlapping `[from, to)` whose categories contain `needle`
    /// (case-insensitive substring over the stored JSON array), ordered by start.
    public func programs(
        inCategoryContaining needle: String,
        from: Date,
        to: Date,
        limit: Int = 200
    ) async throws -> [Program] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let fromEpoch = Int64(from.timeIntervalSince1970)
        let toEpoch = Int64(to.timeIntervalSince1970)
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return try await dbQueue.read { db in
            try Program
                .filter(sql: "categories LIKE ? ESCAPE '\\'", arguments: [pattern])
                .filter(Program.Columns.stop > fromEpoch)
                .filter(Program.Columns.start < toEpoch)
                .order(Program.Columns.start, Program.Columns.channelXmltvID)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Delete programs that overlap `[from, to)` for the given channels, except
    /// rows whose id is listed in `freshIDsByChannel` for that channel.
    ///
    /// Run after upserting a freshly fetched window: a schedule change gives a
    /// program a new row id (ids embed the start time), so the superseded row
    /// isn't overwritten by the upsert and would otherwise overlap the guide
    /// until the history purge ages it out. Channels mapped to an empty id list
    /// are skipped — an empty window in a refresh response is more likely a
    /// partial upstream response than a genuinely blank schedule, and evicting
    /// on it would wipe good cache. Returns the number of rows deleted.
    @discardableResult
    public func evictStalePrograms(
        from: Date,
        to: Date,
        freshIDsByChannel: [String: [String]]
    ) async throws -> Int {
        let fromEpoch = Int64(from.timeIntervalSince1970)
        let toEpoch = Int64(to.timeIntervalSince1970)
        let channels = freshIDsByChannel.filter { !$0.value.isEmpty }
        guard !channels.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            var deleted = 0
            for (channelID, freshIDs) in channels {
                deleted += try Program
                    .filter(Program.Columns.channelXmltvID == channelID)
                    .filter(Program.Columns.stop > fromEpoch)
                    .filter(Program.Columns.start < toEpoch)
                    .filter(!freshIDs.contains(Program.Columns.id))
                    .deleteAll(db)
            }
            return deleted
        }
    }

    /// Delete every program whose `channelXmltvID` starts with `prefix`.
    ///
    /// Demo mode owns the `demo.` prefix, so this removes exactly the generated
    /// sample listings and leaves a user's real Gracenote/XMLTV cache intact.
    /// Matched with `substr` rather than `LIKE` so `_` and `%` in a prefix stay
    /// literal. Returns the number of rows deleted.
    @discardableResult
    public func deletePrograms(channelXmltvIDPrefix prefix: String) async throws -> Int {
        guard !prefix.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            let deleted = try Program
                .filter(sql: "substr(channelXmltvID, 1, ?) = ?", arguments: [prefix.count, prefix])
                .deleteAll(db)
            try db.execute(
                sql: "DELETE FROM channel_icon WHERE substr(xmltvID, 1, ?) = ?",
                arguments: [prefix.count, prefix]
            )
            return deleted
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
