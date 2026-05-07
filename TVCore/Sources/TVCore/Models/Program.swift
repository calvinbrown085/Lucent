import Foundation
import GRDB

public struct Program: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let channelXmltvID: String
    public let title: String
    public let subtitle: String?
    public let desc: String?
    public let start: Date
    public let stop: Date
    public let categories: [String]
    public let episodeNumber: String?
    public let isNew: Bool
    public let isLive: Bool
    public let rating: String?

    public init(
        id: String,
        channelXmltvID: String,
        title: String,
        subtitle: String? = nil,
        desc: String? = nil,
        start: Date,
        stop: Date,
        categories: [String] = [],
        episodeNumber: String? = nil,
        isNew: Bool = false,
        isLive: Bool = false,
        rating: String? = nil
    ) {
        self.id = id
        self.channelXmltvID = channelXmltvID
        self.title = title
        self.subtitle = subtitle
        self.desc = desc
        self.start = start
        self.stop = stop
        self.categories = categories
        self.episodeNumber = episodeNumber
        self.isNew = isNew
        self.isLive = isLive
        self.rating = rating
    }

    public var duration: TimeInterval { stop.timeIntervalSince(start) }
}

extension Program: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "program"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let channelXmltvID = Column(CodingKeys.channelXmltvID)
        public static let title = Column(CodingKeys.title)
        public static let subtitle = Column(CodingKeys.subtitle)
        public static let desc = Column(CodingKeys.desc)
        public static let start = Column(CodingKeys.start)
        public static let stop = Column(CodingKeys.stop)
        public static let categories = Column(CodingKeys.categories)
        public static let episodeNumber = Column(CodingKeys.episodeNumber)
        public static let isNew = Column(CodingKeys.isNew)
        public static let isLive = Column(CodingKeys.isLive)
        public static let rating = Column(CodingKeys.rating)
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.channelXmltvID] = channelXmltvID
        container[Columns.title] = title
        container[Columns.subtitle] = subtitle
        container[Columns.desc] = desc
        container[Columns.start] = Int64(start.timeIntervalSince1970)
        container[Columns.stop] = Int64(stop.timeIntervalSince1970)
        container[Columns.categories] = Self.encodeCategories(categories)
        container[Columns.episodeNumber] = episodeNumber
        container[Columns.isNew] = isNew
        container[Columns.isLive] = isLive
        container[Columns.rating] = rating
    }

    public init(row: Row) throws {
        self.id = row[Columns.id]
        self.channelXmltvID = row[Columns.channelXmltvID]
        self.title = row[Columns.title]
        self.subtitle = row[Columns.subtitle]
        self.desc = row[Columns.desc]
        let startEpoch: Int64 = row[Columns.start]
        let stopEpoch: Int64 = row[Columns.stop]
        self.start = Date(timeIntervalSince1970: TimeInterval(startEpoch))
        self.stop = Date(timeIntervalSince1970: TimeInterval(stopEpoch))
        self.categories = Self.decodeCategories(row[Columns.categories])
        self.episodeNumber = row[Columns.episodeNumber]
        self.isNew = row[Columns.isNew]
        self.isLive = row[Columns.isLive]
        self.rating = row[Columns.rating]
    }

    private static func encodeCategories(_ categories: [String]) -> String {
        guard let data = try? JSONEncoder().encode(categories),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeCategories(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let categories = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return categories
    }
}
