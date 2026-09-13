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

/// One entry of the HDHomeRun `/status.json` array. Keys match the firmware's
/// JSON verbatim. Everything but `Resource` is optional: an idle tuner reports
/// only its name, and older firmware omits some fields entirely.
public struct HDHRTunerStatus: Codable, Sendable, Hashable {
    public let Resource: String
    public let VctNumber: String?
    public let VctName: String?
    public let Frequency: Int?
    public let SignalStrengthPercent: Int?
    public let SignalQualityPercent: Int?
    public let SymbolQualityPercent: Int?
    public let NetworkRate: Int?
    public let TargetIP: String?

    public init(
        Resource: String,
        VctNumber: String? = nil,
        VctName: String? = nil,
        Frequency: Int? = nil,
        SignalStrengthPercent: Int? = nil,
        SignalQualityPercent: Int? = nil,
        SymbolQualityPercent: Int? = nil,
        NetworkRate: Int? = nil,
        TargetIP: String? = nil
    ) {
        self.Resource = Resource
        self.VctNumber = VctNumber
        self.VctName = VctName
        self.Frequency = Frequency
        self.SignalStrengthPercent = SignalStrengthPercent
        self.SignalQualityPercent = SignalQualityPercent
        self.SymbolQualityPercent = SymbolQualityPercent
        self.NetworkRate = NetworkRate
        self.TargetIP = TargetIP
    }
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

    /// Per-tuner signal and lock status from `/status.json`.
    public func tunerStatus() async throws -> [HDHRTunerStatus] {
        let url = try makeURL(path: "status.json")
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
