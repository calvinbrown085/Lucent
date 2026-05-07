import Foundation

public struct HDHRDeviceInfo: Codable, Sendable, Hashable {
    public let DeviceID: String
    public let BaseURL: String?
    public let ModelNumber: String?
    public let FirmwareName: String?
    public let TunerCount: Int?
    public let LineupURL: String?
}

public struct HDHRLineupEntry: Codable, Sendable, Hashable {
    public let GuideNumber: String
    public let GuideName: String
    public let URL: String
    public let HD: Int?
    public let VideoCodec: String?
    public let AudioCodec: String?
}

public enum HDHRClientError: Error, Sendable {
    case invalidIP(String)
    case invalidResponse
    case http(Int)
}

public actor HDHRClient {
    public let host: String
    private let session: URLSession

    public init(host: String, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    public func discover() async throws -> HDHRDeviceInfo {
        let url = try makeURL(path: "discover.json")
        return try await fetchJSON(url)
    }

    public func lineup() async throws -> [HDHRLineupEntry] {
        let url = try makeURL(path: "lineup.json")
        return try await fetchJSON(url)
    }

    /// Translate a discovered device + lineup into ready-to-use `Channel` values.
    /// `xmltvIDForGuideName` lets the caller plug in user-defined overrides; if it
    /// returns nil the GuideName is used verbatim.
    public func channels(
        xmltvIDForGuideName: @Sendable (String) -> String? = { _ in nil }
    ) async throws -> [Channel] {
        let device = try await discover()
        let entries = try await lineup()
        
        return entries.map { entry in
            print(entry)
            let id = "hdhr:\(device.DeviceID):\(entry.GuideNumber)"
            let xmltvID = xmltvIDForGuideName(entry.GuideName) ?? entry.GuideName
            let url = URL(string: entry.URL) ?? URL(fileURLWithPath: "/dev/null")
            return Channel(
                id: id,
                source: .hdhomerun(deviceID: device.DeviceID),
                guideNumber: entry.GuideNumber,
                guideName: entry.GuideName,
                streamURL: url,
                isHD: (entry.HD ?? 0) == 1,
                xmltvID: xmltvID
            )
        }
    }

    private func makeURL(path: String) throws -> URL {
        guard var components = URLComponents(string: "http://\(host)") else {
            throw HDHRClientError.invalidIP(host)
        }
        components.path = "/\(path)"
        guard let url = components.url else {
            throw HDHRClientError.invalidIP(host)
        }
        return url
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw HDHRClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw HDHRClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
