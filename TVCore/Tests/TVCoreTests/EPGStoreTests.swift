import Testing
import Foundation
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
