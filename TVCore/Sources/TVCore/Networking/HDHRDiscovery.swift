import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct HDHRDiscoveredDevice: Sendable, Hashable, Identifiable, Codable {
    public let host: String
    public let info: HDHRDeviceInfo

    public var id: String { info.DeviceID }

    public init(host: String, info: HDHRDeviceInfo) {
        self.host = host
        self.info = info
    }
}

public actor HDHRDiscovery {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession()
    }

    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    /// Probe `<subnet>.1` through `<subnet>.254` for HDHomeRun devices.
    /// 254 short-timeout requests in parallel — completes in 1–2 s on a healthy LAN.
    public func scan(subnet: String, timeout: TimeInterval = 0.5) async -> [HDHRDiscoveredDevice] {
        let trimmed = subnet.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let session = self.session
        let devices = await withTaskGroup(of: HDHRDiscoveredDevice?.self) { group in
            for suffix in 1...254 {
                let host = "\(trimmed).\(suffix)"
                group.addTask { await Self.probe(host: host, session: session, timeout: timeout) }
            }
            var found: [HDHRDiscoveredDevice] = []
            for await device in group {
                if let device { found.append(device) }
            }
            return found
        }
        return devices.sorted { $0.host < $1.host }
    }

    /// Detect the active LAN interface's /24 and scan it. Returns [] if no LAN is up.
    public func scanLocalSubnet(timeout: TimeInterval = 0.5) async -> [HDHRDiscoveredDevice] {
        guard let subnet = Self.currentIPv4Subnet() else { return [] }
        return await scan(subnet: subnet, timeout: timeout)
    }

    /// First non-loopback, non-link-local, non-VPN IPv4 interface, with the
    /// last octet stripped. e.g. en0 = 192.168.1.42 → "192.168.1".
    public static func currentIPv4Subnet() -> String? {
        guard let address = currentIPv4Address() else { return nil }
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    public static func currentIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cursor = ptr {
            defer { ptr = cursor.pointee.ifa_next }

            let flags = Int32(cursor.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            guard let addr = cursor.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: cursor.pointee.ifa_name)
            // Skip VPN tunnels, AWDL, p2p — we want the LAN interface.
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ipsec") {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard ok == 0 else { continue }

            let host = String(cString: hostBuffer)
            // Reject link-local 169.254.x.x.
            if host.hasPrefix("169.254.") { continue }
            return host
        }
        return nil
    }

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 1.0
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private static func probe(host: String, session: URLSession, timeout: TimeInterval) async -> HDHRDiscoveredDevice? {
        guard let url = URL(string: "http://\(host)/discover.json") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let info = try JSONDecoder().decode(HDHRDeviceInfo.self, from: data)
            // discover.json from non-HDHR servers may decode partially if they happen to
            // share field names; require a non-empty DeviceID as a sanity check.
            guard !info.DeviceID.isEmpty else { return nil }
            return HDHRDiscoveredDevice(host: host, info: info)
        } catch {
            return nil
        }
    }
}
