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
