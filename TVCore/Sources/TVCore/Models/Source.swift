import Foundation

/// Where a `Channel` originates. The discriminant exists so v2 can add
/// non-HDHomeRun providers (ErsatzTV, Channels DVR, etc.) without
/// reshaping `Channel` itself.
public enum Source: Codable, Hashable, Sendable {
    case hdhomerun(deviceID: String)
}
