import Foundation

public struct Channel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let source: Source
    public let guideNumber: String
    public let guideName: String
    public let streamURL: URL
    public let isHD: Bool
    public var xmltvID: String
    public var iconURL: URL?

    public init(
        id: String,
        source: Source,
        guideNumber: String,
        guideName: String,
        streamURL: URL,
        isHD: Bool,
        xmltvID: String,
        iconURL: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.guideNumber = guideNumber
        self.guideName = guideName
        self.streamURL = streamURL
        self.isHD = isHD
        self.xmltvID = xmltvID
        self.iconURL = iconURL
    }
}
