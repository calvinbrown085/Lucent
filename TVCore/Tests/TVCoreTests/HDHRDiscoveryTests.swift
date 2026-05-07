import Testing
import Foundation
@testable import TVCore

@Suite(.serialized) struct HDHRDiscoveryTests {

    @Test
    func findsRespondingHostsAndIgnoresOthers() async throws {
        // 10.0.0.7 and 10.0.0.42 respond as HDHomeRuns. Everyone else 404s.
        MockHDHRProtocol.canned = [
            "10.0.0.7": #"{"DeviceID":"ABCD1234","ModelNumber":"HDHR4-2US","FirmwareName":"hdhomerun4_atsc_20250101","TunerCount":2,"BaseURL":"http://10.0.0.7","LineupURL":"http://10.0.0.7/lineup.json"}"#,
            "10.0.0.42": #"{"DeviceID":"ABCD5678","ModelNumber":"HDHR5-4DT","FirmwareName":"hdhomerun5_dvbt_20250101","TunerCount":4,"BaseURL":"http://10.0.0.42","LineupURL":"http://10.0.0.42/lineup.json"}"#,
        ]
        defer { MockHDHRProtocol.canned = [:] }

        let discovery = HDHRDiscovery(configuration: MockHDHRProtocol.makeConfig())
        let devices = await discovery.scan(subnet: "10.0.0", timeout: 0.05)

        #expect(devices.count == 2)
        #expect(devices.map(\.host) == ["10.0.0.42", "10.0.0.7"] || devices.map(\.host) == ["10.0.0.7", "10.0.0.42"])

        let byHost = Dictionary(uniqueKeysWithValues: devices.map { ($0.host, $0) })
        #expect(byHost["10.0.0.7"]?.info.DeviceID == "ABCD1234")
        #expect(byHost["10.0.0.7"]?.info.TunerCount == 2)
        #expect(byHost["10.0.0.42"]?.info.DeviceID == "ABCD5678")
        #expect(byHost["10.0.0.42"]?.info.TunerCount == 4)
    }

    @Test
    func ignoresJSONWithoutDeviceID() async throws {
        // A non-HDHR server happens to return JSON with the same field names but blank DeviceID — drop it.
        MockHDHRProtocol.canned = [
            "10.0.0.5": #"{"DeviceID":"","ModelNumber":"x","FirmwareName":"y","TunerCount":1,"BaseURL":null,"LineupURL":null}"#,
        ]
        defer { MockHDHRProtocol.canned = [:] }

        let discovery = HDHRDiscovery(configuration: MockHDHRProtocol.makeConfig())
        let devices = await discovery.scan(subnet: "10.0.0", timeout: 0.05)
        #expect(devices.isEmpty)
    }

    @Test
    func emptySubnetReturnsEmpty() async {
        let discovery = HDHRDiscovery(configuration: MockHDHRProtocol.makeConfig())
        let devices = await discovery.scan(subnet: "", timeout: 0.05)
        #expect(devices.isEmpty)
    }
}

/// URLProtocol subclass that intercepts http://<host>/discover.json requests
/// and serves canned bodies (or fails) based on the host. Lets us test the full
/// 254-host sweep without touching the network.
private final class MockHDHRProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var canned: [String: String] = [:]
    private static let lock = NSLock()

    static func makeConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHDHRProtocol.self]
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let body = Self.canned[host]
        Self.lock.unlock()

        if let body, let data = body.data(using: .utf8) {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            // Non-responder — synthesize a fast failure (simulating a host that's not an HDHR).
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() {}
}
