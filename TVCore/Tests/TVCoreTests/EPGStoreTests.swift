import Testing
import Foundation
import GRDB
@testable import TVCore

@Suite struct EPGStoreTests {

    @Test
    func ingestAndWindowQuery() async throws {
        let store = try makeStore()
        let programs = sampleSequence(for: "KCCI.com", anchor: anchor, count: 5, durationMinutes: 30)
        try await store.ingest(stream(of: programs))

        // Query a window that covers programs 1, 2, 3 (zero-indexed: starts within the window).
        let from = anchor.addingTimeInterval(30 * 60)        // start of program 1
        let to = anchor.addingTimeInterval(30 * 60 * 4)      // end of program 3
        let result = try await store.programs(channelXmltvID: "KCCI.com", from: from, to: to)
        #expect(result.map(\.title) == ["Show 1", "Show 2", "Show 3"])
    }

    @Test
    func nowPlayingHitsAndMisses() async throws {
        let store = try makeStore()
        let programs = sampleSequence(for: "KCCI.com", anchor: anchor, count: 3, durationMinutes: 30)
        try await store.ingest(stream(of: programs))

        // Halfway through Show 1.
        let mid = anchor.addingTimeInterval(30 * 60 + 15 * 60)
        let hit = try await store.nowPlaying(channelXmltvID: "KCCI.com", at: mid)
        #expect(hit?.title == "Show 1")

        // Way after the last program ends.
        let after = anchor.addingTimeInterval(60 * 60 * 24)
        let miss = try await store.nowPlaying(channelXmltvID: "KCCI.com", at: after)
        #expect(miss == nil)
    }

    @Test
    func reingestReplacesByPrimaryKey() async throws {
        let store = try makeStore()
        let original = sampleSequence(for: "KCCI.com", anchor: anchor, count: 2, durationMinutes: 30)
        try await store.ingest(stream(of: original))

        // Same IDs (anchored on start time) but mutated titles.
        var mutated = original
        mutated[0] = Program(
            id: original[0].id,
            channelXmltvID: original[0].channelXmltvID,
            title: "Updated Show 0",
            start: original[0].start,
            stop: original[0].stop
        )
        try await store.ingest(stream(of: mutated))

        let from = anchor.addingTimeInterval(-1)
        let to = anchor.addingTimeInterval(60 * 60 * 5)
        let result = try await store.programs(channelXmltvID: "KCCI.com", from: from, to: to)
        #expect(result.count == 2)
        #expect(result[0].title == "Updated Show 0")
    }

    @Test
    func nowPlayingBatchReturnsCurrentProgramsForMultipleChannels() async throws {
        let store = try makeStore()
        let chA = sampleSequence(for: "A.com", anchor: anchor, count: 3, durationMinutes: 30)
        let chB = sampleSequence(for: "B.com", anchor: anchor, count: 3, durationMinutes: 30)
        let chC = sampleSequence(for: "C.com", anchor: anchor, count: 3, durationMinutes: 30)
        try await store.ingest(stream(of: chA + chB + chC))

        let mid = anchor.addingTimeInterval(15 * 60) // halfway through Show 0
        let result = try await store.nowPlayingBatch(
            channelXmltvIDs: ["A.com", "B.com", "C.com"],
            at: mid
        )

        #expect(result.count == 3)
        #expect(result["A.com"]?.title == "Show 0")
        #expect(result["B.com"]?.title == "Show 0")
        #expect(result["C.com"]?.title == "Show 0")
    }

    @Test
    func nowPlayingBatchOmitsChannelsWithNoCurrentProgram() async throws {
        let store = try makeStore()
        let chA = sampleSequence(for: "A.com", anchor: anchor, count: 2, durationMinutes: 30)
        try await store.ingest(stream(of: chA))

        let mid = anchor.addingTimeInterval(15 * 60)
        let result = try await store.nowPlayingBatch(
            channelXmltvIDs: ["A.com", "B.com"],
            at: mid
        )

        // B.com has no programs ingested → absent from the result.
        #expect(result.count == 1)
        #expect(result["A.com"]?.title == "Show 0")
        #expect(result["B.com"] == nil)
    }

    @Test
    func nowPlayingBatchEmptyInputReturnsEmpty() async throws {
        let store = try makeStore()
        let result = try await store.nowPlayingBatch(channelXmltvIDs: [], at: anchor)
        #expect(result.isEmpty)
    }

    @Test
    func purgeOlderThanRemovesEndedPrograms() async throws {
        let store = try makeStore()
        let programs = sampleSequence(for: "KCCI.com", anchor: anchor, count: 4, durationMinutes: 30)
        try await store.ingest(stream(of: programs))

        // Cutoff after the second program ends => first two go away.
        let cutoff = anchor.addingTimeInterval(30 * 60 * 2 + 1)
        try await store.purgeOlderThan(cutoff)

        let result = try await store.programs(
            channelXmltvID: "KCCI.com",
            from: anchor,
            to: anchor.addingTimeInterval(60 * 60 * 5)
        )
        #expect(result.map(\.title) == ["Show 2", "Show 3"])
    }

    @Test
    func evictStaleProgramsDropsSupersededRowsButKeepsFreshAndOutOfWindow() async throws {
        let store = try makeStore()
        let original = sampleSequence(for: "KCCI.com", anchor: anchor, count: 4, durationMinutes: 30)
        try await store.ingest(stream(of: original))

        // Schedule change: Show 1 now starts 15 minutes later, which gives it a
        // new start-anchored id. Upsert leaves the superseded row in place.
        let shiftedStart = original[1].start.addingTimeInterval(15 * 60)
        let shifted = Program(
            id: "KCCI.com:\(Int64(shiftedStart.timeIntervalSince1970))",
            channelXmltvID: "KCCI.com",
            title: "Show 1 (moved)",
            start: shiftedStart,
            stop: shiftedStart.addingTimeInterval(30 * 60)
        )
        try await store.ingest(stream(of: [original[0], shifted, original[2]]))

        // Evict a window covering Shows 0–2, keeping only the fresh ids.
        // Show 3 starts beyond the window and must survive.
        let windowEnd = anchor.addingTimeInterval(30 * 60 * 3)
        let deleted = try await store.evictStalePrograms(
            from: anchor,
            to: windowEnd,
            freshIDsByChannel: ["KCCI.com": [original[0].id, shifted.id, original[2].id]]
        )
        #expect(deleted == 1)

        let result = try await store.programs(
            channelXmltvID: "KCCI.com",
            from: anchor,
            to: anchor.addingTimeInterval(60 * 60 * 5)
        )
        #expect(result.map(\.title) == ["Show 0", "Show 1 (moved)", "Show 2", "Show 3"])
    }

    @Test
    func evictStaleProgramsSkipsChannelsWithEmptyKeepList() async throws {
        let store = try makeStore()
        let programs = sampleSequence(for: "KCCI.com", anchor: anchor, count: 2, durationMinutes: 30)
        try await store.ingest(stream(of: programs))

        // An empty keep-list looks like a partial upstream response — nothing
        // should be evicted on its account.
        let deleted = try await store.evictStalePrograms(
            from: anchor,
            to: anchor.addingTimeInterval(60 * 60 * 6),
            freshIDsByChannel: ["KCCI.com": []]
        )
        #expect(deleted == 0)

        let result = try await store.programs(
            channelXmltvID: "KCCI.com",
            from: anchor,
            to: anchor.addingTimeInterval(60 * 60 * 5)
        )
        #expect(result.count == 2)
    }

    @Test
    func evictStaleProgramsLeavesOtherChannelsAlone() async throws {
        let store = try makeStore()
        let chA = sampleSequence(for: "A.com", anchor: anchor, count: 2, durationMinutes: 30)
        let chB = sampleSequence(for: "B.com", anchor: anchor, count: 2, durationMinutes: 30)
        try await store.ingest(stream(of: chA + chB))

        // Fresh response only covers A.com and keeps just its first program.
        let deleted = try await store.evictStalePrograms(
            from: anchor,
            to: anchor.addingTimeInterval(60 * 60 * 6),
            freshIDsByChannel: ["A.com": [chA[0].id]]
        )
        #expect(deleted == 1)

        let bResult = try await store.programs(
            channelXmltvID: "B.com",
            from: anchor,
            to: anchor.addingTimeInterval(60 * 60 * 5)
        )
        #expect(bResult.count == 2)
    }

    // MARK: - v3 metadata

    @Test
    func yearAndCreditsRoundTrip() async throws {
        let store = try makeStore()
        let movie = Program(
            id: "M.com:1",
            channelXmltvID: "M.com",
            title: "Copper Line",
            start: anchor,
            stop: anchor.addingTimeInterval(105 * 60),
            categories: ["Movie"],
            year: 2018,
            credits: ["Rafael Okonkwo", "Della Hartigan"]
        )
        let plain = Program(
            id: "M.com:2",
            channelXmltvID: "M.com",
            title: "Filler",
            start: movie.stop,
            stop: movie.stop.addingTimeInterval(1800)
        )
        try await store.ingest(stream(of: [movie, plain]))

        let rows = try await store.programs(channelXmltvID: "M.com", from: anchor, to: anchor.addingTimeInterval(86_400))
        #expect(rows.count == 2)
        #expect(rows[0].year == 2018)
        #expect(rows[0].credits == ["Rafael Okonkwo", "Della Hartigan"])
        #expect(rows[1].year == nil)
        #expect(rows[1].credits == [])
    }

    /// A database created by the v1/v2 schema (before `year`/`credits` and the
    /// FTS index existed) must upgrade in place: old rows decode with defaults
    /// and the rebuilt FTS index finds them.
    @Test
    func upgradesLegacyDatabaseAndIndexesExistingRows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lucent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "epg.sqlite")

        do {
            let legacy = try DatabaseQueue(path: url.path)
            defer { try? legacy.close() }
            try await legacy.write { db in
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
                try db.execute(sql: """
                    CREATE TABLE channel_icon (
                        xmltvID TEXT PRIMARY KEY,
                        iconURL TEXT NOT NULL,
                        updatedAt INTEGER NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1_program'), ('v2_channel_icon')")
                try db.execute(
                    sql: "INSERT INTO program (id, channelXmltvID, title, start, stop) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["L:1", "L.com", "Legacy Listing", Int64(anchor.timeIntervalSince1970), Int64(anchor.timeIntervalSince1970) + 3600]
                )
            }
        }

        let store = try EPGStore(databaseURL: url)
        let found = try await store.search("legacy", from: anchor.addingTimeInterval(-1))
        #expect(found.map(\.id) == ["L:1"])
        #expect(found.first?.year == nil)
        #expect(found.first?.credits == [])
    }

    // MARK: - search

    @Test
    func searchPrefixMatchesTitleSubtitleAndDescription() async throws {
        let store = try makeStore()
        let base = anchor
        let rows = [
            Program(id: "A:1", channelXmltvID: "A", title: "Kettle & Crumb", subtitle: "Bread Week",
                    start: base, stop: base.addingTimeInterval(3600)),
            Program(id: "B:1", channelXmltvID: "B", title: "Evening News", subtitle: nil,
                    desc: "Headlines, plus the kettle drum championship.",
                    start: base.addingTimeInterval(3600), stop: base.addingTimeInterval(7200)),
            Program(id: "C:1", channelXmltvID: "C", title: "Garden Hours", subtitle: "Beds",
                    start: base.addingTimeInterval(7200), stop: base.addingTimeInterval(10_800)),
        ]
        try await store.ingest(stream(of: rows))

        let kett = try await store.search("kett", from: base.addingTimeInterval(-1))
        #expect(kett.map(\.id) == ["A:1", "B:1"])

        let bread = try await store.search("BREAD", from: base.addingTimeInterval(-1))
        #expect(bread.map(\.id) == ["A:1"])

        // Multiple words AND together.
        let both = try await store.search("kettle crumb", from: base.addingTimeInterval(-1))
        #expect(both.map(\.id) == ["A:1"])

        // Ended programs are excluded.
        let later = try await store.search("kettle", from: base.addingTimeInterval(3601))
        #expect(later.map(\.id) == ["B:1"])

        let none = try await store.search("zzzz", from: base)
        #expect(none.isEmpty)
    }

    @Test
    func searchToleratesWeirdInput() async throws {
        let store = try makeStore()
        let rows = sampleSequence(for: "A.com", anchor: anchor, count: 2, durationMinutes: 30)
        try await store.ingest(stream(of: rows))
        let from = anchor.addingTimeInterval(-1)

        for weird in ["\"", "AND", "OR NOT", "*", "(", "\"show\"", "show*", "show:1", "NEAR(a b)", "^show", "-", "'", "sh\"ow"] {
            let result = try await store.search(weird, from: from)
            _ = result  // must not throw
        }
        // Operators are treated as plain words, not syntax.
        #expect(try await store.search("AND", from: from).isEmpty)
        #expect(try await store.search("\"show\"", from: from).count == 2)
        #expect(try await store.search("   ", from: from).isEmpty)
        #expect(try await store.search("", from: from).isEmpty)
        #expect(try await store.search("\"", from: from).isEmpty)
    }

    @Test
    func searchCollapsesRepeatAiringsKeepingEarliest() async throws {
        let store = try makeStore()
        let base = anchor
        let rows = [
            Program(id: "A:1", channelXmltvID: "A", title: "Ward Nine", subtitle: "Triage",
                    start: base, stop: base.addingTimeInterval(3600)),
            Program(id: "A:2", channelXmltvID: "A", title: "Ward Nine", subtitle: "Triage",
                    start: base.addingTimeInterval(86_400), stop: base.addingTimeInterval(90_000)),
            Program(id: "A:3", channelXmltvID: "A", title: "Ward Nine", subtitle: "Handoff",
                    start: base.addingTimeInterval(3600), stop: base.addingTimeInterval(7200)),
            Program(id: "B:1", channelXmltvID: "B", title: "Ward Nine", subtitle: "Triage",
                    start: base.addingTimeInterval(1800), stop: base.addingTimeInterval(5400)),
        ]
        try await store.ingest(stream(of: rows))

        let result = try await store.search("ward", from: base.addingTimeInterval(-1))
        #expect(result.map(\.id) == ["A:1", "B:1", "A:3"])

        let limited = try await store.search("ward", from: base.addingTimeInterval(-1), limit: 2)
        #expect(limited.map(\.id) == ["A:1", "B:1"])
    }

    @Test
    func searchIndexFollowsUpdatesAndDeletes() async throws {
        let store = try makeStore()
        let original = Program(id: "A:1", channelXmltvID: "A", title: "Old Title",
                               start: anchor, stop: anchor.addingTimeInterval(3600))
        try await store.ingest(stream(of: [original]))
        #expect(try await store.search("old", from: anchor).count == 1)

        let renamed = Program(id: "A:1", channelXmltvID: "A", title: "Fresh Title",
                              start: anchor, stop: anchor.addingTimeInterval(3600))
        try await store.ingest(stream(of: [renamed]))
        #expect(try await store.search("old", from: anchor).isEmpty)
        #expect(try await store.search("fresh", from: anchor).map(\.id) == ["A:1"])

        try await store.purgeOlderThan(anchor.addingTimeInterval(86_400))
        #expect(try await store.search("fresh", from: anchor.addingTimeInterval(-86_400)).isEmpty)
    }

    @Test
    func ftsMatchExpressionSanitises() {
        #expect(EPGStore.ftsMatchExpression("kettle crumb") == "\"kettle\"* \"crumb\"*")
        #expect(EPGStore.ftsMatchExpression("  \"AND\" ") == "\"AND\"*")
        #expect(EPGStore.ftsMatchExpression("don't") == "\"dont\"*")
        #expect(EPGStore.ftsMatchExpression("\"") == nil)
        #expect(EPGStore.ftsMatchExpression("") == nil)
        #expect(EPGStore.ftsMatchExpression("   ") == nil)
    }

    // MARK: - airings

    @Test
    func airingsOfTitleMatchCaseInsensitivelyAcrossChannels() async throws {
        let store = try makeStore()
        let base = anchor
        let rows = [
            Program(id: "A:1", channelXmltvID: "A", title: "Deep Field", start: base, stop: base.addingTimeInterval(3600)),
            Program(id: "B:1", channelXmltvID: "B", title: "deep field", start: base.addingTimeInterval(7200), stop: base.addingTimeInterval(10_800)),
            Program(id: "A:2", channelXmltvID: "A", title: "DEEP FIELD", start: base.addingTimeInterval(3600), stop: base.addingTimeInterval(7200)),
            Program(id: "C:1", channelXmltvID: "C", title: "Deep Fields", start: base, stop: base.addingTimeInterval(3600)),
            Program(id: "A:3", channelXmltvID: "A", title: "Deep Field", start: base.addingTimeInterval(200_000), stop: base.addingTimeInterval(203_600)),
        ]
        try await store.ingest(stream(of: rows))

        let result = try await store.airings(
            ofTitle: "Deep Field",
            excludingID: "A:1",
            from: base.addingTimeInterval(-1),
            to: base.addingTimeInterval(86_400)
        )
        #expect(result.map(\.id) == ["A:2", "B:1"])

        let all = try await store.airings(ofTitle: "deep FIELD", excludingID: nil, from: base.addingTimeInterval(-1), to: base.addingTimeInterval(86_400), limit: 1)
        #expect(all.map(\.id) == ["A:1"])

        #expect(try await store.airings(ofTitle: "", excludingID: nil, from: base, to: base.addingTimeInterval(86_400)).isEmpty)
    }

    // MARK: - upNextBatch

    @Test
    func upNextBatchReturnsTheProgramAfterNow() async throws {
        let store = try makeStore()
        let chA = sampleSequence(for: "A.com", anchor: anchor, count: 3, durationMinutes: 30)
        let chB = sampleSequence(for: "B.com", anchor: anchor, count: 1, durationMinutes: 30)
        try await store.ingest(stream(of: chA + chB))

        let mid = anchor.addingTimeInterval(15 * 60) // during Show 0
        let result = try await store.upNextBatch(channelXmltvIDs: ["A.com", "B.com", "C.com"], at: mid)
        #expect(result.count == 1)
        #expect(result["A.com"]?.title == "Show 1")
        #expect(result["B.com"] == nil)   // nothing after Show 0
        #expect(result["C.com"] == nil)   // unknown channel

        // Exactly at a boundary, "next" is the one strictly after that start.
        let atStart = anchor.addingTimeInterval(30 * 60)
        let boundary = try await store.upNextBatch(channelXmltvIDs: ["A.com"], at: atStart)
        #expect(boundary["A.com"]?.title == "Show 2")

        #expect(try await store.upNextBatch(channelXmltvIDs: [], at: mid).isEmpty)
    }

    // MARK: - categories

    @Test
    func programsInCategoryContainingMatchesCaseInsensitively() async throws {
        let store = try makeStore()
        let base = anchor
        let rows = [
            Program(id: "A:1", channelXmltvID: "A", title: "Ball Game", start: base, stop: base.addingTimeInterval(3600), categories: ["Sports", "Baseball"]),
            Program(id: "B:1", channelXmltvID: "B", title: "Late Movie", start: base.addingTimeInterval(1800), stop: base.addingTimeInterval(9000), categories: ["Movie", "Drama"]),
            Program(id: "C:1", channelXmltvID: "C", title: "Motorsport", start: base.addingTimeInterval(3600), stop: base.addingTimeInterval(7200), categories: ["SPORTS EVENT"]),
            Program(id: "D:1", channelXmltvID: "D", title: "Old Game", start: base.addingTimeInterval(-7200), stop: base.addingTimeInterval(-3600), categories: ["Sports"]),
        ]
        try await store.ingest(stream(of: rows))

        let sports = try await store.programs(inCategoryContaining: "sport", from: base, to: base.addingTimeInterval(86_400))
        #expect(sports.map(\.id) == ["A:1", "C:1"])

        let movies = try await store.programs(inCategoryContaining: "Movie", from: base, to: base.addingTimeInterval(86_400))
        #expect(movies.map(\.id) == ["B:1"])

        // LIKE wildcards in the needle are literal.
        #expect(try await store.programs(inCategoryContaining: "%", from: base, to: base.addingTimeInterval(86_400)).isEmpty)
        #expect(try await store.programs(inCategoryContaining: "", from: base, to: base.addingTimeInterval(86_400)).isEmpty)
    }

    // MARK: helpers

    /// 2026-04-01 18:00 UTC. Avoiding `.now` keeps the tests deterministic.
    private let anchor = Date(timeIntervalSince1970: 1_775_080_800)

    private func makeStore() throws -> EPGStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lucent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try EPGStore(databaseURL: dir.appending(path: "epg.sqlite"))
    }

    private func sampleSequence(
        for channel: String,
        anchor: Date,
        count: Int,
        durationMinutes: Int
    ) -> [Program] {
        (0..<count).map { i in
            let start = anchor.addingTimeInterval(Double(i) * Double(durationMinutes) * 60)
            let stop = start.addingTimeInterval(Double(durationMinutes) * 60)
            return Program(
                id: "\(channel):\(Int64(start.timeIntervalSince1970))",
                channelXmltvID: channel,
                title: "Show \(i)",
                start: start,
                stop: stop
            )
        }
    }

    private func stream(of programs: [Program]) -> AsyncThrowingStream<XMLTVEvent, Error> {
        AsyncThrowingStream { continuation in
            for p in programs { continuation.yield(.program(p)) }
            continuation.finish()
        }
    }
}
