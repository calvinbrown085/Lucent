import Testing
import Foundation
@testable import TVCore

struct XMLTVParserTests {

    @Test
    func parsesChannelsAndPrograms() async throws {
        let url = try fixtureURL()
        let parser = XMLTVParser()
        var channels: [(String, [String], URL?)] = []
        var programs: [Program] = []
        for try await event in parser.parse(contentsOf: url) {
            switch event {
            case .channel(let id, let names, let icon): channels.append((id, names, icon))
            case .program(let p): programs.append(p)
            }
        }
        #expect(channels.count == 2)
        #expect(channels[0].0 == "KCCI.com")
        #expect(channels[0].1 == ["KCCI-HD", "8.1"])
        #expect(channels[0].2 == URL(string: "https://example.com/logos/kcci.png"))
        #expect(channels[1].0 == "WHO.com")
        #expect(channels[1].2 == nil)

        #expect(programs.count == 4)
    }

    @Test
    func decodesProgramFields() async throws {
        let programs = try await collectPrograms()
        let lateNews = try #require(programs.first { $0.title == "Late News" })
        #expect(lateNews.channelXmltvID == "KCCI.com")
        #expect(lateNews.subtitle == "Overnight Edition")
        #expect(lateNews.desc == "Local headlines.")
        #expect(lateNews.categories == ["News"])
        #expect(lateNews.isNew == true)
        #expect(lateNews.isLive == false)

        let sundayMorning = try #require(programs.first { $0.title == "Sunday Morning" })
        #expect(sundayMorning.isLive == true)
        #expect(sundayMorning.categories == ["News", "Magazine"])

        let today = try #require(programs.first { $0.title == "Today on NBC" })
        #expect(today.rating == "TV-PG")
    }

    @Test
    func parsesDSTBoundaryWithExplicitOffsets() async throws {
        // The fixture has a -0600 program ending exactly when the -0500 program starts.
        // Both timestamps refer to the same wall clock instant; epoch should match.
        let programs = try await collectPrograms()
        let lateNews = try #require(programs.first { $0.title == "Late News" })
        let sundayMorning = try #require(programs.first { $0.title == "Sunday Morning" })

        // Late News stops at 02:00 CST = 08:00 UTC.
        // Sunday Morning starts at 03:00 CDT = 08:00 UTC.
        #expect(lateNews.stop == sundayMorning.start)
    }

    @Test
    func programIDsAreStableAcrossParses() async throws {
        let first = try await collectPrograms().map(\.id).sorted()
        let second = try await collectPrograms().map(\.id).sorted()
        #expect(first == second)
    }

    @Test
    func parsesCreditsDateAndOnscreenEpisodeNumber() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme channel="X.com" start="20260308030000 -0500" stop="20260308050000 -0500">
            <title>Copper Line</title>
            <credits>
              <director> Della Hartigan </director>
              <actor role="Wes">Rafael Okonkwo</actor>
              <actor>Ines Marlow</actor>
              <presenter>Teodor Vance</presenter>
              <writer>Nobody Counted</writer>
            </credits>
            <date>20180412</date>
            <category>Movie</category>
            <episode-num system="xmltv_ns">1.4.0/1</episode-num>
            <episode-num system="onscreen">S02E05</episode-num>
          </programme>
          <programme channel="X.com" start="20260308050000 -0500" stop="20260308060000 -0500">
            <title>Later</title>
            <date>1999</date>
            <episode-num system="onscreen">S01E01</episode-num>
            <episode-num system="xmltv_ns">0.0.0/1</episode-num>
          </programme>
          <programme channel="X.com" start="20260308060000 -0500" stop="20260308070000 -0500">
            <title>Undated</title>
            <date>n/a</date>
            <episode-num system="dd_progid">EP01.0001</episode-num>
          </programme>
        </tv>
        """
        var programs: [Program] = []
        for try await event in XMLTVParser().parse(data: Data(xml.utf8)) {
            if case .program(let p) = event { programs.append(p) }
        }
        #expect(programs.count == 3)

        let movie = try #require(programs.first { $0.title == "Copper Line" })
        #expect(movie.credits == ["Della Hartigan", "Rafael Okonkwo", "Ines Marlow", "Teodor Vance"])
        #expect(movie.year == 2018)
        #expect(movie.episodeNumber == "S02E05")
        #expect(movie.categories == ["Movie"])

        // Onscreen wins regardless of document order.
        let later = try #require(programs.first { $0.title == "Later" })
        #expect(later.year == 1999)
        #expect(later.episodeNumber == "S01E01")
        #expect(later.credits.isEmpty)

        // No onscreen form: fall back to whatever system is present.
        let undated = try #require(programs.first { $0.title == "Undated" })
        #expect(undated.year == nil)
        #expect(undated.episodeNumber == "EP01.0001")
    }

    @Test
    func fixtureProgramsHaveNoCreditsOrYear() async throws {
        let programs = try await collectPrograms()
        #expect(programs.allSatisfy { $0.credits.isEmpty && $0.year == nil })
    }

    // MARK: helpers

    private func collectPrograms() async throws -> [Program] {
        let url = try fixtureURL()
        let parser = XMLTVParser()
        var out: [Program] = []
        for try await event in parser.parse(contentsOf: url) {
            if case .program(let p) = event { out.append(p) }
        }
        return out
    }

    private func fixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "sample", withExtension: "xmltv", subdirectory: "Resources") else {
            throw XCTAssertionError(message: "sample.xmltv missing from test bundle")
        }
        return url
    }
}

private struct XCTAssertionError: Error {
    let message: String
}
