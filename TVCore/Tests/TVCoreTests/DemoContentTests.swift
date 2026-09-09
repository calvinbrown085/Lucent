import Testing
import Foundation
@testable import TVCore

@Suite struct DemoContentTests {

    @Test
    func recognizesTheAddressToken() {
        #expect(DemoContent.isDemoAddress("demo"))
        #expect(DemoContent.isDemoAddress("  DEMO "))
        #expect(DemoContent.isDemoAddress("Demo\n"))
        #expect(!DemoContent.isDemoAddress("demo.local"))
        #expect(!DemoContent.isDemoAddress("192.168.1.50"))
        #expect(!DemoContent.isDemoAddress(""))
    }

    @Test
    func lineupIsWellFormed() {
        let channels = DemoContent.channels()
        #expect(channels.count >= 10)
        #expect(Set(channels.map(\.id)).count == channels.count)
        #expect(Set(channels.map(\.guideNumber)).count == channels.count)
        for channel in channels {
            #expect(channel.xmltvID == DemoContent.xmltvIDPrefix + channel.guideNumber)
            #expect(channel.source == .hdhomerun(deviceID: DemoContent.deviceID))
        }
    }

    /// Every channel must have something on right now — a reviewer opening the
    /// app to empty cells would read as a broken build.
    @Test
    func everyChannelIsOnAirAtTheAnchor() {
        let programs = DemoContent.programs(anchor: anchor)
        let byChannel = Dictionary(grouping: programs, by: \.channelXmltvID)
        #expect(byChannel.count == DemoContent.channels().count)
        for channel in DemoContent.channels() {
            let onNow = byChannel[channel.xmltvID]?.filter { $0.start <= anchor && $0.stop > anchor }
            #expect(onNow?.count == 1, "\(channel.guideNumber) has \(onNow?.count ?? 0) programs at the anchor")
        }
    }

    @Test
    func schedulesAreContiguousAndCoverTheFullWindow() {
        let programs = DemoContent.programs(anchor: anchor)
        let byChannel = Dictionary(grouping: programs, by: \.channelXmltvID)
        for (channelID, rows) in byChannel {
            let sorted = rows.sorted { $0.start < $1.start }
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                #expect(previous.stop == next.start, "gap or overlap on \(channelID) at \(previous.stop)")
            }
            #expect(sorted.first!.start <= anchor.addingTimeInterval(-Double(DemoContent.lookbackHours) * 3600 + 1800))
            #expect(sorted.last!.stop >= anchor.addingTimeInterval(Double(DemoContent.forwardDays) * 86_400))
            #expect(Set(sorted.map(\.id)).count == sorted.count)
        }
    }

    /// Re-seeding must upsert rather than duplicate, so ids may not drift for a
    /// given anchor.
    @Test
    func generationIsStableForAnAnchor() {
        let first = DemoContent.programs(anchor: anchor)
        let second = DemoContent.programs(anchor: anchor.addingTimeInterval(60))
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.title) == second.map(\.title))
    }

    @Test
    func programsCarryGuideMetadata() {
        let programs = DemoContent.programs(anchor: anchor)
        #expect(programs.allSatisfy { !$0.title.isEmpty })
        #expect(programs.allSatisfy { !($0.desc ?? "").isEmpty })
        #expect(programs.allSatisfy { $0.categories.count == 1 })
        #expect(programs.contains { $0.isNew })
        #expect(programs.contains { $0.isLive })
        #expect(programs.contains { $0.episodeNumber != nil })
    }

    @Test
    func ingestsAndPurgesWithoutTouchingRealListings() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lucent-demo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try EPGStore(databaseURL: dir.appending(path: "epg.sqlite"))

        // A real listing that must survive the demo purge.
        let real = Program(
            id: "real:1",
            channelXmltvID: "8.1",
            title: "Real Program",
            start: anchor,
            stop: anchor.addingTimeInterval(1800)
        )
        try await store.ingest(
            AsyncThrowingStream { continuation in
                continuation.yield(.program(real))
                continuation.finish()
            }
        )
        try await store.ingest(DemoContent.events(anchor: anchor))

        let channel = DemoContent.channels()[0]
        let onNow = try await store.nowPlaying(channelXmltvID: channel.xmltvID, at: anchor)
        #expect(onNow != nil)

        let deleted = try await store.deletePrograms(channelXmltvIDPrefix: DemoContent.xmltvIDPrefix)
        #expect(deleted == DemoContent.programs(anchor: anchor).count)
        #expect(try await store.totalProgramCount() == 1)
        #expect(try await store.nowPlaying(channelXmltvID: "8.1", at: anchor)?.title == "Real Program")
    }

    /// 2026-04-01 18:00 UTC — already on a half-hour boundary, so the generated
    /// window lines up exactly with the anchor.
    private let anchor = Date(timeIntervalSince1970: 1_775_080_800)
}
