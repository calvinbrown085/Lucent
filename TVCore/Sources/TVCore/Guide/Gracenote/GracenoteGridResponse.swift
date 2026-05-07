import Foundation

/// Decodable shape of `https://tvlistings.gracenote.com/api/grid` responses.
/// Field set is intentionally permissive — Gracenote's payload is undocumented
/// and varies by region, so most fields are optional.
public struct GracenoteGridResponse: Decodable, Sendable {
    public let channels: [GracenoteChannel]
}

public struct GracenoteChannel: Decodable, Sendable {
    public let channelId: String?
    public let channelNo: String?
    public let callSign: String?
    public let affiliateName: String?
    public let thumbnail: String?
    public let events: [GracenoteEvent]?
}

public struct GracenoteEvent: Decodable, Sendable {
    public let startTime: String
    public let endTime: String
    public let duration: String?
    public let thumbnail: String?
    public let rating: String?
    public let flag: [String]?
    public let tags: [String]?
    public let seriesId: String?
    public let programId: String?
    public let program: GracenoteProgram?
}

public struct GracenoteProgram: Decodable, Sendable {
    public let id: String?
    public let title: String?
    public let episodeTitle: String?
    public let shortDesc: String?
    public let longDesc: String?
    public let releaseYear: String?
    public let season: String?
    public let episode: String?
    public let genres: [String]?
}
