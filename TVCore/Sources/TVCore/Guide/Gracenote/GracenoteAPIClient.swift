import Foundation

public struct GracenoteLineup: Sendable, Equatable {
    public let lineupID: String
    public let headendID: String
    public let postalCode: String
    public let country: String
    public let device: String

    public init(lineupID: String, headendID: String, postalCode: String, country: String, device: String = "X") {
        self.lineupID = lineupID
        self.headendID = headendID
        self.postalCode = postalCode
        self.country = country
        self.device = device
    }

    /// Default OTA lineup derived from a postal code, e.g. `USA-OTA10001-DEFAULT`.
    /// The `-DEFAULT` suffix and the literal `"lineupId"` headendId are what
    /// tvlistings.gracenote.com's grid endpoint expects for OTA lookups.
    public static func ota(postalCode: String, country: String = "USA") -> GracenoteLineup {
        let id = "\(country)-OTA\(postalCode)-DEFAULT"
        return GracenoteLineup(lineupID: id, headendID: "lineupId", postalCode: postalCode, country: country, device: "-")
    }
}

public enum GracenoteAPIError: Error, Sendable {
    case requestFailed(Int)
    case invalidURL
    case decoding(String)
}

public struct GracenoteAPIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://tvlistings.gracenote.com/api/grid")!

    /// Gracenote's grid endpoint accepts `timespan` up to 6 hours per request.
    public static let chunkHours: Int = 6

    private let baseURL: URL
    private let session: URLSession
    private let userAgent: String

    public init(
        baseURL: URL = GracenoteAPIClient.defaultBaseURL,
        session: URLSession = .shared,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    ) {
        self.baseURL = baseURL
        self.session = session
        self.userAgent = userAgent
    }

    public func fetchChunk(
        startingAt start: Date,
        timespanHours: Int = GracenoteAPIClient.chunkHours,
        timeZoneOffsetSeconds: Int = TimeZone.current.secondsFromGMT(),
        lineup: GracenoteLineup
    ) async throws -> GracenoteGridResponse {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let timezoneHours = Double(timeZoneOffsetSeconds) / 3600.0
        let timezoneString = String(format: "%g", timezoneHours)
        components?.queryItems = [
            URLQueryItem(name: "lineupId", value: lineup.lineupID),
            URLQueryItem(name: "timespan", value: String(timespanHours)),
            URLQueryItem(name: "headendId", value: lineup.headendID),
            URLQueryItem(name: "country", value: lineup.country),
            URLQueryItem(name: "timezone", value: timezoneString),
            URLQueryItem(name: "device", value: lineup.device),
            URLQueryItem(name: "postalCode", value: lineup.postalCode),
            URLQueryItem(name: "isOverride", value: "true"),
            URLQueryItem(name: "time", value: String(Int64(start.timeIntervalSince1970))),
            URLQueryItem(name: "pref", value: "16,128"),
            URLQueryItem(name: "userId", value: "-"),
            URLQueryItem(name: "aid", value: "orbebb"),
            URLQueryItem(name: "languagecode", value: "en-us"),
        ]
        guard let url = components?.url else { throw GracenoteAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://tvlistings.gracenote.com/", forHTTPHeaderField: "Referer")

        #if DEBUG
        print("[Lucent][Gracenote] GET \(url.absoluteString)")
        #endif
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            #if DEBUG
            let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? "<\(data.count) non-utf8 bytes>"
            print("[Lucent][Gracenote] HTTP \(http.statusCode). body: \(bodyPreview)")
            #endif
            throw GracenoteAPIError.requestFailed(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(GracenoteGridResponse.self, from: data)
        } catch {
            #if DEBUG
            let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? "<\(data.count) bytes>"
            print("[Lucent][Gracenote] decode failed. body preview: \(bodyPreview)")
            #endif
            throw GracenoteAPIError.decoding(String(describing: error))
        }
    }
}
