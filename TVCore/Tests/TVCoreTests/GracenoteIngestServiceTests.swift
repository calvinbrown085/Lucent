import Foundation
import Testing
@testable import TVCore

@Suite struct GracenoteIngestServiceTests {

    @Test
    func decodesFixtureAndYieldsPrograms() async throws {
        let response = try loadFixture()
        let stream = GracenoteIngestService.programStream(from: response)
        var programs: [Program] = []
        for try await event in stream {
            if case .program(let p) = event { programs.append(p) }
        }
        #expect(programs.count == 3)
        // channelNo is preferred over callSign — matches HDHR's GuideNumber.
        #expect(programs.contains { $0.title == "Local News" && $0.channelXmltvID == "8.1" })
        #expect(programs.contains { $0.title == "Movie Night" && $0.channelXmltvID == "13.1" })
    }

    @Test
    func mapsEventFieldsCorrectly() async throws {
        let response = try loadFixture()
        let stream = GracenoteIngestService.programStream(from: response)
        var programs: [Program] = []
        for try await event in stream {
            if case .program(let p) = event { programs.append(p) }
        }
        let news = try #require(programs.first { $0.title == "Local News" })
        #expect(news.subtitle == "Evening Edition")
        #expect(news.desc == "Tonight's headlines.")
        #expect(news.categories == ["News"])
        #expect(news.isNew == true)
        #expect(news.isLive == false)
        #expect(news.rating == "TV-PG")
        #expect(news.episodeNumber == "S12E187")

        let game = try #require(programs.first { $0.title == "Game Show Hour" })
        #expect(game.isLive == true)
        #expect(game.isNew == false)
        #expect(game.episodeNumber == nil)

        let movie = try #require(programs.first { $0.title == "Movie Night" })
        #expect(movie.desc == "A long-form description.")
        #expect(movie.categories == ["Movie", "Drama"])
    }

    @Test
    func parsesBothISODateFormats() async throws {
        // Fixture has KCCI (no seconds in timestamp) and WHO (with seconds).
        let response = try loadFixture()
        let stream = GracenoteIngestService.programStream(from: response)
        var programs: [Program] = []
        for try await event in stream {
            if case .program(let p) = event { programs.append(p) }
        }
        let news = try #require(programs.first { $0.title == "Local News" })
        let movie = try #require(programs.first { $0.title == "Movie Night" })
        #expect(news.start == movie.start)  // both "2026-05-06T22:00Z"
        #expect(movie.stop.timeIntervalSince(movie.start) == 3600)
    }

    @Test
    func skipsChannelsWithoutCallsignAndChannelNumber() async throws {
        let response = try loadFixture()
        let stream = GracenoteIngestService.programStream(from: response)
        var ids = Set<String>()
        for try await event in stream {
            if case .program(let p) = event { ids.insert(p.channelXmltvID) }
        }
        // The empty-callsign channel has channelNo "5.1" but no events, so it
        // never yields a program — only the two real channels show up, keyed
        // by channelNo for HDHR-side joinability.
        #expect(ids == ["8.1", "13.1"])
    }

    @Test
    func emitsChannelIconEventsForThumbnails() async throws {
        let response = try loadFixture()
        let stream = GracenoteIngestService.programStream(from: response)
        var icons: [String: URL] = [:]
        for try await event in stream {
            if case .channel(let id, _, let iconURL) = event, let iconURL {
                icons[id] = iconURL
            }
        }
        #expect(icons["8.1"]?.absoluteString == "https://zap2it.tmsimg.com/assets/p10001_h_h15_aa.png")
        #expect(icons["13.1"] == nil)
    }

    @Test
    func thumbnailURLResolvesRelativeAndPassesAbsolute() {
        #expect(GracenoteIngestService.thumbnailURL(nil) == nil)
        #expect(GracenoteIngestService.thumbnailURL("") == nil)
        #expect(GracenoteIngestService.thumbnailURL("/assets/p1.png")?.absoluteString
                == "https://zap2it.tmsimg.com/assets/p1.png")
        #expect(GracenoteIngestService.thumbnailURL("https://example.com/x.png")?.absoluteString
                == "https://example.com/x.png")
    }

    @Test
    func ingestPersistsChannelIcons() async throws {
        let store = try makeStore()
        let response = try loadFixture()
        try await store.ingest(GracenoteIngestService.programStream(from: response))
        let icons = try await store.iconURLs()
        #expect(icons["8.1"]?.absoluteString == "https://zap2it.tmsimg.com/assets/p10001_h_h15_aa.png")
        #expect(icons["13.1"] == nil)
    }

    @Test
    func ingestPipesProgramsIntoEPGStore() async throws {
        let store = try makeStore()
        let response = try loadFixture()
        try await store.ingest(GracenoteIngestService.programStream(from: response))

        // Fixture programs are anchored at 2026-05-06T22:00Z; query a wide window
        // so we don't depend on hardcoded epoch math.
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 4_000_000_000)
        let kcciPrograms = try await store.programs(channelXmltvID: "8.1", from: from, to: to)
        #expect(kcciPrograms.map(\.title) == ["Local News", "Game Show Hour"])
    }

    // MARK: helpers

    private func loadFixture() throws -> GracenoteGridResponse {
        guard let url = Bundle.module.url(
            forResource: "gracenote-grid",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw FixtureError.missing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GracenoteGridResponse.self, from: data)
    }

    private func makeStore() throws -> EPGStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lucent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try EPGStore(databaseURL: dir.appending(path: "epg.sqlite"))
    }

    private enum FixtureError: Error { case missing }
}
