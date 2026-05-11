import Foundation
import Observation
import TVCore

@Observable
@MainActor
final class AppModel {
    let settings = SettingsStore()
    let player = PlayerCoordinator()
    let location = LocationService()
    let sleepTimer = SleepTimer()
    let favoritesSync: FavoritesCloudSync
    #if !os(tvOS)
    let pip = PIPController()
    #endif

    /// Set true when the sleep timer fires `onExpire` — NowPlayingView observes
    /// this to dismiss itself, then resets the flag.
    var sleepTimerDidExpire = false

    private(set) var channels: [Channel] = []
    private(set) var device: HDHRDeviceInfo?
    private(set) var bootstrapError: String?
    private(set) var isRefreshingEPG = false
    private(set) var discoveredDevices: [HDHRDiscoveredDevice] = []
    private(set) var isScanning = false
    private(set) var isResolvingLocation = false
    private(set) var xmltvIDsWithPrograms: Set<String> = []
    var locationError: String?
    var lastEPGRefresh: Date?

    private let epgStore: EPGStore
    private let epgService: EPGService
    private let gracenoteIngest: GracenoteIngestService
    private let discovery = HDHRDiscovery()

    init() {
        do {
            self.epgStore = try EPGStore.defaultStoreRecovering()
        } catch {
            fatalError("Could not open EPG cache after recovery: \(error)")
        }
        self.epgService = EPGService(store: epgStore)
        self.gracenoteIngest = GracenoteIngestService(store: epgStore)
        self.favoritesSync = FavoritesCloudSync(settings: settings)
        self.player.prewarmCount = settings.prewarmCount
        // AsyncImage uses URLSession.shared, which respects URLCache.shared. Give
        // it a real disk budget so channel logos don't refetch on every launch.
        URLCache.shared = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "lucent-images"
        )
        sleepTimer.onExpire = { [weak self] in
            guard let self else { return }
            #if !os(tvOS)
            self.pip.stop()
            #endif
            self.player.tearDown()
            self.sleepTimerDidExpire = true
        }
        #if !os(tvOS)
        pip.onShouldTearDownPlayer = { [weak self] in
            self?.player.tearDown()
        }
        #endif
    }

    /// Discover the configured HDHR, build the channel list with overrides applied,
    /// and kick off an XMLTV refresh in the background.
    func bootstrap() async {
        bootstrapError = nil
        favoritesSync.start()

        // First-launch convenience: no IP saved → scan the LAN, and if exactly
        // one HDHR responds, claim it automatically. The first probe to a
        // local IP also triggers the iOS Local Network permission prompt;
        // users routinely take several seconds to tap Allow, so retry until
        // a scan finds something or we exhaust the budget (~10 s).
        if settings.hdhrIP.isEmpty {
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                await scanForDevices()
                if !discoveredDevices.isEmpty { break }
            }
            if discoveredDevices.count == 1 {
                settings.hdhrIP = discoveredDevices[0].host
            }
        }
        guard !settings.hdhrIP.isEmpty else { return }

        let client = HDHRClient(host: settings.hdhrIP)
        do {
            let device = try await client.discover()
            self.device = device
            if let count = device.TunerCount { player.availableTuners = count }

            let entries = try await client.lineup()
            self.channels = entries.map { entry in
                let id = "hdhr:\(device.DeviceID):\(entry.GuideNumber)"
                let url = URL(string: entry.URL) ?? URL(fileURLWithPath: "/dev/null")
                return Channel(
                    id: id,
                    source: .hdhomerun(deviceID: device.DeviceID),
                    guideNumber: entry.GuideNumber,
                    guideName: entry.GuideName,
                    streamURL: url,
                    isHD: (entry.HD ?? 0) == 1,
                    xmltvID: resolvedXmltvID(channelID: id, guideNumber: entry.GuideNumber, guideName: entry.GuideName)
                )
            }
            await applyChannelIcons()
            await refreshChannelsWithProgramsCache()
        } catch {
            bootstrapError = String(describing: error)
        }

        await refreshGuide()
    }

    /// Hydrate `channel.iconURL` from the cached channel_icon table. Cheap; safe
    /// to call after bootstrap and after every guide refresh.
    func applyChannelIcons() async {
        let icons: [String: URL]
        do {
            icons = try await epgStore.iconURLs()
        } catch {
            return
        }
        guard !icons.isEmpty else { return }
        channels = channels.map { ch in
            var copy = ch
            copy.iconURL = icons[ch.xmltvID]
            return copy
        }
    }

    /// Probe the local /24 for HDHomeRun units. Safe to call repeatedly.
    func scanForDevices() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        discoveredDevices = await discovery.scanLocalSubnet()
    }

    /// User picked a device from the discovered list — adopt it and re-bootstrap.
    func selectDiscovered(_ device: HDHRDiscoveredDevice) async {
        settings.hdhrIP = device.host
        await bootstrap()
    }

    func refreshEPG(from url: URL) async {
        isRefreshingEPG = true
        defer { isRefreshingEPG = false }
        do {
            try await epgService.refresh(from: url)
            self.lastEPGRefresh = await epgService.lastRefresh
        } catch {
            bootstrapError = "EPG refresh failed: \(error)"
        }
    }

    /// Refresh program data using the configured guide source. Gracenote needs a
    /// postal code; if we don't have one yet, prompt for location.
    func refreshGuide() async {
        rebuildChannelMapping()
        #if DEBUG
        print("[Lucent][AppModel] refreshGuide source=\(settings.guideSource) channels=\(channels.count) sampleXmltvIDs=\(channels.prefix(5).map(\.xmltvID))")
        #endif
        switch settings.guideSource {
        case .gracenote:
            let zip = settings.postalCode.trimmingCharacters(in: .whitespaces)
            guard !zip.isEmpty else {
                bootstrapError = "Set a postal code in Settings (or tap “Use my location”) to load listings."
                return
            }
            let country = settings.countryCode.trimmingCharacters(in: .whitespaces).uppercased().isEmpty
                ? "USA" : settings.countryCode.trimmingCharacters(in: .whitespaces).uppercased()
            let lineupOverride = settings.lineupIDOverride.trimmingCharacters(in: .whitespaces)
            let lineup: GracenoteLineup = lineupOverride.isEmpty
                ? .ota(postalCode: zip, country: country)
                : GracenoteLineup(lineupID: lineupOverride, headendID: lineupOverride, postalCode: zip, country: country)

            isRefreshingEPG = true
            defer { isRefreshingEPG = false }
            do {
                try await gracenoteIngest.refresh(lineup: lineup, hours: 24)
                self.lastEPGRefresh = await gracenoteIngest.lastRefresh
                bootstrapError = nil
                await applyChannelIcons()
                #if DEBUG
                await dumpStoreStats()
                #endif
                await refreshChannelsWithProgramsCache()
            } catch {
                #if DEBUG
                print("[Lucent][AppModel] Gracenote refresh threw: \(error)")
                #endif
                bootstrapError = "Guide refresh failed: \(error)"
            }
        case .xmltvURL:
            guard let url = settings.xmltvURL else {
                bootstrapError = "Enter an XMLTV URL in Settings to load listings."
                return
            }
            await refreshEPG(from: url)
            await applyChannelIcons()
            await refreshChannelsWithProgramsCache()
        }
    }

    func updatePostalCodeFromLocation() async {
        isResolvingLocation = true
        locationError = nil
        defer { isResolvingLocation = false }
        do {
            let pc = try await location.requestPostalCode()
            settings.postalCode = pc.postalCode
            settings.countryCode = pc.country
        } catch {
            locationError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: - Facade for views

    func programs(for channel: Channel, from: Date, to: Date) async throws -> [Program] {
        let result = try await epgStore.programs(channelXmltvID: channel.xmltvID, from: from, to: to)
        #if DEBUG
        print("[Lucent][AppModel] query channelXmltvID=\(channel.xmltvID) (guide=\(channel.guideNumber) name=\(channel.guideName)) → \(result.count) programs")
        #endif
        return result
    }

    #if DEBUG
    /// Print a snapshot of what's actually stored in the EPG cache and how it
    /// lines up with the channels we know about. Use after a refresh to spot
    /// xmltvID mismatches at a glance. Debug-only.
    func dumpStoreStats() async {
        do {
            let total = try await epgStore.totalProgramCount()
            let stats = try await epgStore.channelStats()
            print("[Lucent][AppModel] store totalPrograms=\(total) distinctChannels=\(stats.count)")
            for s in stats.prefix(15) {
                print("[Lucent][AppModel]   stored \(s.channelXmltvID) → \(s.programCount) programs")
            }
            let storedKeys = Set(stats.map(\.channelXmltvID))
            let channelKeys = Set(channels.map(\.xmltvID))
            let missing = channelKeys.subtracting(storedKeys).sorted()
            let unmatched = storedKeys.subtracting(channelKeys).sorted()
            print("[Lucent][AppModel] channels-without-listings=\(missing.prefix(15))")
            print("[Lucent][AppModel] stored-keys-no-channel=\(unmatched.prefix(15))")
        } catch {
            print("[Lucent][AppModel] dumpStoreStats failed: \(error)")
        }
    }
    #endif

    func nowPlaying(for channel: Channel, at instant: Date = .now) async throws -> Program? {
        try await epgStore.nowPlaying(channelXmltvID: channel.xmltvID, at: instant)
    }

    /// Batch "what's on now" for the mini-guide. One DB read instead of N.
    /// Returns a dictionary keyed by `Channel.id` (not xmltvID) so callers can
    /// look up by the same identifier they pass in.
    func nowPlayingBatch(for channels: [Channel], at instant: Date = .now) async throws -> [String: Program] {
        let xmltvIDs = channels.map(\.xmltvID)
        let byXmltv = try await epgStore.nowPlayingBatch(channelXmltvIDs: xmltvIDs, at: instant)
        var byChannelID: [String: Program] = [:]
        byChannelID.reserveCapacity(channels.count)
        for c in channels {
            if let p = byXmltv[c.xmltvID] { byChannelID[c.id] = p }
        }
        return byChannelID
    }

    /// Pull the set of xmltvIDs that currently have programs from the EPG cache.
    /// Drives `visibleChannels` when "Hide channels without guide data" is on.
    func refreshChannelsWithProgramsCache() async {
        do {
            let stats = try await epgStore.channelStats()
            xmltvIDsWithPrograms = Set(stats.map(\.channelXmltvID))
        } catch {
            xmltvIDsWithPrograms = []
        }
    }

    // MARK: - Mutations

    func tune(to channel: Channel) {
        player.tune(to: channel)
        updatePrewarmNeighbors(for: channel)
    }

    func tuneAdjacent(offset: Int) {
        // Walk visibleChannels so up/down skips channels the user has hidden.
        // Fall back to the full list if the filter would leave nothing to tune.
        let pool = visibleChannels.isEmpty ? channels : visibleChannels
        guard let current = player.activeChannel,
              !pool.isEmpty else { return }
        let idx = pool.firstIndex(where: { $0.id == current.id }) ?? -1
        let nextIdx = idx < 0
            ? (offset > 0 ? 0 : pool.count - 1)
            : (idx + offset + pool.count) % pool.count
        tune(to: pool[nextIdx])
    }

    func setXMLTVOverride(channelID: String, xmltvID: String?) {
        settings.setOverride(channelID: channelID, xmltvID: xmltvID)
        if let i = channels.firstIndex(where: { $0.id == channelID }) {
            var c = channels[i]
            c.xmltvID = resolvedXmltvID(channelID: channelID, guideNumber: c.guideNumber, guideName: c.guideName)
            channels[i] = c
        }
    }

    /// Compute the join key a channel should use to look up programs in the
    /// EPG store. The right key depends on the active guide source:
    /// - **Gracenote** stores programs keyed by channel number (e.g. "8.1") —
    ///   matches HDHR's `GuideNumber` exactly, including subchannels.
    /// - **XMLTV** uses whatever channel id the source file declares; default
    ///   to `GuideName`, allow per-channel override.
    private func resolvedXmltvID(channelID: String, guideNumber: String, guideName: String) -> String {
        if let override = settings.xmltvOverrides[channelID]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return override
        }
        switch settings.guideSource {
        case .gracenote: return guideNumber
        case .xmltvURL: return guideName
        }
    }

    /// Re-resolve every channel's xmltvID against the current guide source.
    /// Call after switching sources or when overrides change in bulk.
    func rebuildChannelMapping() {
        channels = channels.map { ch in
            var copy = ch
            copy.xmltvID = resolvedXmltvID(channelID: ch.id, guideNumber: ch.guideNumber, guideName: ch.guideName)
            return copy
        }
    }

    func toggleFavorite(_ channel: Channel) {
        settings.toggleFavorite(channel.id)
        favoritesSync.push(settings.favorites)
    }

    func isFavorite(_ channel: Channel) -> Bool {
        settings.favorites.contains(channel.id)
    }

    func setPrewarmCount(_ count: Int) {
        settings.prewarmCount = count
        player.prewarmCount = count
        if let active = player.activeChannel {
            updatePrewarmNeighbors(for: active)
        }
    }

    /// Channels the user should see in the grid and guide. Two filters compose:
    /// - "Hide channels without guide data" (only once the program cache has
    ///   loaded — falls back to the full list pre-refresh so the screen isn't
    ///   blank).
    /// - User-hidden channels (`settings.hiddenChannels`) — managed via
    ///   ManageChannelsView.
    var visibleChannels: [Channel] {
        var result = channels
        if settings.hideChannelsWithoutGuide, !xmltvIDsWithPrograms.isEmpty {
            result = result.filter { xmltvIDsWithPrograms.contains($0.xmltvID) }
        }
        if !settings.hiddenChannels.isEmpty {
            result = result.filter { !settings.hiddenChannels.contains($0.id) }
        }
        return result
    }

    var favoriteChannels: [Channel] {
        visibleChannels.filter { settings.favorites.contains($0.id) }
    }

    private func updatePrewarmNeighbors(for channel: Channel) {
        // Match tuneAdjacent's pool so we prewarm the channels the user can
        // actually flip to with up/down.
        let pool = visibleChannels.isEmpty ? channels : visibleChannels
        guard let idx = pool.firstIndex(where: { $0.id == channel.id }), pool.count > 1 else {
            player.updatePrewarm(neighbors: [])
            return
        }
        let next = (idx + 1) % pool.count
        let prev = (idx - 1 + pool.count) % pool.count
        var neighbors: [Channel] = []
        if next != idx { neighbors.append(pool[next]) }
        if prev != idx, prev != next { neighbors.append(pool[prev]) }
        player.updatePrewarm(neighbors: neighbors)
    }
}
