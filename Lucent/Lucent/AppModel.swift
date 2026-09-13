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
    let audioMonitor = AudioLatencyMonitor()
    let reminders = ReminderService()
    #if !os(tvOS)
    let pip = PIPController()
    #endif

    /// A channel some out-of-band path (reminder banner, notification tap,
    /// deep link, docked-player expand) wants to watch fullscreen. `RootView`
    /// presents Now Playing for it and clears it on dismiss.
    var pendingTuneChannel: Channel?

    /// Set by `RootView` when the current layout has room for the docked
    /// player (iPad regular width). `NowPlayingView` flips
    /// `isFullscreenPresented` while it's on screen so the dock and the
    /// fullscreen view never both mount `VLCPlayerView` at once.
    var dockedPlayerLayout = false
    var isFullscreenPresented = false

    /// True when a tune should land in the docked pane rather than open
    /// Now Playing fullscreen.
    var prefersDockedPlayback: Bool {
        dockedPlayerLayout && settings.dockedPlayerEnabled
    }

    var dockedPlayerVisible: Bool {
        prefersDockedPlayback && player.activeChannel != nil && !isFullscreenPresented
    }

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
        // Seed video-pipeline latency estimate. Correcting by full
        // `-outputLatency` overshoots (audio ends up ahead of video) because
        // VLC's own decode/drawable pipeline isn't zero-latency — it partially
        // cancels the audio output latency. 100 ms is a starting guess; tune
        // up to delay audio more, down to advance audio more.
        audioMonitor.videoPipelineLatencyMicros = 50_000
        audioMonitor.userOffsetMicros = settings.audioSyncOffsetMillis * 1000
        audioMonitor.onChange = { [weak self] micros in
            self?.player.applyAudioDelayToAllPlayers(micros)
        }
        audioMonitor.start()
        player.captionsPreferred = settings.captionsEnabled
        player.deinterlaceFilter = settings.deinterlaceMode.vlcFilterName
        if FeatureFlags.reminders { reminders.start() }
        #if !os(tvOS)
        player.usesMemoryOutput = settings.pipEnabled
        pip.onShouldTearDownPlayer = { [weak self] in
            self?.player.tearDown()
        }
        pip.onRestoreUserInterface = { [weak self] in
            guard let self, !self.isFullscreenPresented, !self.dockedPlayerVisible,
                  let ch = self.player.activeChannel else { return }
            self.pendingTuneChannel = ch
        }
        // Install libVLC's memory callbacks on whichever player is about to
        // play. Must fire before its first play() — see PlayerCoordinator.
        player.onActivePlayerWillChange = { [weak self] newPlayer in
            self?.pip.attachVLCSource(newPlayer)
        }
        #endif
    }

    /// Deinterlacer change applies to new players; retune so it's immediate.
    func setDeinterlaceMode(_ mode: DeinterlaceMode) {
        settings.deinterlaceMode = mode
        player.deinterlaceFilter = mode.vlcFilterName
        if let active = player.activeChannel {
            player.tearDown()
            tune(to: active)
        }
    }

    #if !os(tvOS)
    /// Flip the rendering path. Takes effect on the next tune; if something
    /// is playing, retune it now so the change is immediate.
    func setPiPEnabled(_ enabled: Bool) {
        settings.pipEnabled = enabled
        if pip.isActive { pip.stop() }
        player.usesMemoryOutput = enabled
        if let active = player.activeChannel {
            player.tearDown()
            tune(to: active)
        }
    }
    #endif

    /// Discover the configured HDHR, build the channel list with overrides applied,
    /// and kick off an XMLTV refresh in the background.
    func bootstrap() async {
        bootstrapError = nil
        favoritesSync.start()

        // Demo mode: skip discovery, the tuner and the network entirely.
        if isDemoMode {
            await bootstrapDemo()
            return
        }

        // Coming back from demo mode (or launching after it): drop the
        // generated listings and put the player back on the real pipeline.
        if player.isDemoMode {
            player.tearDown()
            player.isDemoMode = false
        }
        await purgeDemoListings()

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

        if let pending = pendingWatchChannelID {
            pendingWatchChannelID = nil
            watch(channelID: pending)
        }
        if let number = pendingWatchNumber {
            pendingWatchNumber = nil
            watch(number: number)
        }
        #if DEBUG
        // Profiling hook: `xctrace record --launch --env LUCENT_AUTOWATCH=8.1`
        // starts the app under Instruments and lands straight on a stream.
        // Empty value resumes the last-watched channel.
        if pendingWatchNumber == nil, let auto = ProcessInfo.processInfo.environment["LUCENT_AUTOWATCH"] {
            watch(number: auto)
        }
        #endif
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
            bootstrapError = nil
        } catch {
            bootstrapError = "EPG refresh failed: \(error)"
        }
    }

    /// Refresh program data using the configured guide source. Gracenote needs a
    /// postal code; if we don't have one yet, prompt for location.
    func refreshGuide() async {
        rebuildChannelMapping()
        if isDemoMode {
            await seedDemoContent()
            return
        }
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
                try await gracenoteIngest.refresh(lineup: lineup, hours: 24 * 7)
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
        // LocationService holds a single continuation per request; a second
        // concurrent call would overwrite it and strand the first caller.
        guard !isResolvingLocation else { return }
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

    // MARK: - Demo mode

    /// True when the user has typed `demo` into the device-address field.
    /// Demo mode replaces the tuner, the guide provider and the video decoder
    /// with locally generated stand-ins so the app can be reviewed end to end
    /// with no HDHomeRun on the network.
    var isDemoMode: Bool {
        DemoContent.isDemoAddress(settings.hdhrIP)
    }

    /// True once the demo lineup has actually been adopted — `isDemoMode` flips
    /// as soon as the address field reads `demo`, which is one keystroke before
    /// the lineup exists. Views use this to avoid re-bootstrapping.
    var isDemoLoaded: Bool {
        isDemoMode && device?.DeviceID == DemoContent.deviceID
    }

    /// Stand-in for the discover + lineup round trip. No network, no scan.
    private func bootstrapDemo() async {
        player.isDemoMode = true
        let info = DemoContent.deviceInfo
        device = info
        if let count = info.TunerCount { player.availableTuners = count }
        channels = DemoContent.channels()
        await seedDemoContent()
    }

    /// Regenerate the sample listings and write them through the same
    /// `EPGStore.ingest` path Gracenote and XMLTV use.
    ///
    /// Existing demo rows are dropped first: each seed re-anchors the schedule
    /// to the current half hour, so rows generated from an older anchor would
    /// otherwise linger and overlap in the grid.
    private func seedDemoContent() async {
        isRefreshingEPG = true
        defer { isRefreshingEPG = false }
        do {
            try await epgStore.deletePrograms(channelXmltvIDPrefix: DemoContent.xmltvIDPrefix)
            settings.demoListingsPresent = true
            try await epgStore.ingest(DemoContent.events())
            lastEPGRefresh = .now
            bootstrapError = nil
            await refreshChannelsWithProgramsCache()
        } catch {
            bootstrapError = "Demo data could not be loaded: \(error)"
        }
    }

    /// Drop the generated listings if any are in the cache. Cheap no-op
    /// otherwise — the flag is what keeps this off the hot launch path for
    /// users who have never opened demo mode.
    private func purgeDemoListings() async {
        guard settings.demoListingsPresent else { return }
        try? await epgStore.deletePrograms(channelXmltvIDPrefix: DemoContent.xmltvIDPrefix)
        settings.demoListingsPresent = false
    }

    /// Leave demo mode from Settings: stop the simulated stream, clear the
    /// address field and fall back to a normal first-launch bootstrap, which
    /// purges the sample listings on its way through.
    func exitDemoMode() async {
        settings.hdhrIP = ""
        channels = []
        device = nil
        lastEPGRefresh = nil
        await bootstrap()
        await refreshChannelsWithProgramsCache()
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
        player.isDemoMode = isDemoMode
        player.captionsPreferred = settings.captionsEnabled
        player.tune(to: channel)
        updatePrewarmNeighbors(for: channel)
        settings.recordRecent(channel.id)
    }

    func tune(toChannelID id: String) {
        guard let ch = channels.first(where: { $0.id == id }) else { return }
        tune(to: ch)
    }

    /// The channel watched before the active one, for the "last channel"
    /// toggle. Recents are newest-first with the active channel at index 0.
    var previousChannel: Channel? {
        let ids = settings.recentChannelIDs
        let candidates = ids.filter { $0 != player.activeChannel?.id }
        guard let id = candidates.first else { return nil }
        return channels.first { $0.id == id }
    }

    func tuneToPreviousChannel() {
        guard let prev = previousChannel else { return }
        tune(to: prev)
    }

    /// Recently watched channels (newest first), excluding hidden ones.
    var recentChannels: [Channel] {
        let visible = visibleChannels
        return settings.recentChannelIDs.compactMap { id in visible.first { $0.id == id } }
    }

    /// Persisted captions preference + live apply.
    func toggleCaptions() {
        player.toggleCaptions()
        settings.captionsEnabled = player.captionsPreferred
    }

    /// A watch request that arrived before the lineup loaded (cold-launch
    /// notification tap or deep link). Resolved at the end of `bootstrap`.
    private var pendingWatchChannelID: String?

    /// Watch a channel from wherever the app currently is: fullscreen, or
    /// into the docked pane on iPad when that's the user's preference.
    func watch(channelID: String) {
        guard let ch = channels.first(where: { $0.id == channelID }) else {
            if channels.isEmpty { pendingWatchChannelID = channelID }
            return
        }
        tune(to: ch)
        if !prefersDockedPlayback {
            pendingTuneChannel = ch
        }
    }

    /// `lucent://tune/<channelID>`, `lucent://tune?number=8.1`, or bare
    /// `lucent://tune` (resume the last-watched channel, else the first).
    /// Any of these arriving before the lineup has loaded is deferred to the
    /// end of `bootstrap`.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "lucent", url.host?.lowercased() == "tune" else { return }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            watch(channelID: path.removingPercentEncoding ?? path)
            return
        }
        let number = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "number" })?.value
        guard !channels.isEmpty else {
            pendingWatchNumber = number ?? ""
            return
        }
        watch(number: number)
    }

    /// Empty string means "resume last watched / first channel".
    private var pendingWatchNumber: String?

    private func watch(number: String?) {
        let target: Channel?
        if let number, !number.isEmpty {
            target = channels.first { $0.guideNumber == number }
        } else {
            target = recentChannels.first ?? visibleChannels.first ?? channels.first
        }
        if let target { watch(channelID: target.id) }
    }

    // MARK: - Scene lifecycle

    /// Channel stopped by `sceneDidEnterBackground`, resumed on return.
    private var channelToResume: Channel?
    private var backgroundStopTask: Task<Void, Never>?

    /// Leaving the foreground ends playback: tvOS has no PiP, so audio
    /// carrying on under the home screen is never wanted. On iOS the stop
    /// is deferred briefly so system PiP gets the chance to take the stream
    /// over; if it doesn't (PiP off, or not possible yet), we stop too.
    func sceneDidEnterBackground() {
        backgroundStopTask?.cancel()
        #if os(tvOS)
        stopForBackground()
        #else
        backgroundStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            if !self.pip.isActive { self.stopForBackground() }
        }
        #endif
    }

    func sceneDidBecomeActive() {
        backgroundStopTask?.cancel()
        guard let ch = channelToResume else { return }
        channelToResume = nil
        // Only resume if a player surface is still up; otherwise the user
        // had left playback and we shouldn't grab a tuner unprompted.
        if isFullscreenPresented || dockedPlayerVisible || pendingTuneChannel != nil {
            tune(to: ch)
        }
    }

    private func stopForBackground() {
        guard let ch = player.activeChannel else { return }
        channelToResume = ch
        player.tearDown()
    }

    // MARK: - Tuner status

    /// Per-tuner signal readings from the HDHR (`/status.json`). Demo mode
    /// synthesises a healthy-looking reading so the overlay can be reviewed.
    func tunerStatus() async -> [HDHRTunerStatus] {
        if isDemoMode {
            let n = player.activeChannel?.guideNumber ?? "1.1"
            let wobble = Int(Date.now.timeIntervalSince1970) % 5
            return [HDHRTunerStatus(
                Resource: "tuner0", VctNumber: n, VctName: player.activeChannel?.guideName,
                Frequency: 189_000_000, SignalStrengthPercent: 88 + wobble,
                SignalQualityPercent: 84 + wobble, SymbolQualityPercent: 100,
                NetworkRate: 9_130_000, TargetIP: nil
            )]
        }
        guard !settings.hdhrIP.isEmpty else { return [] }
        return (try? await HDHRClient(host: settings.hdhrIP).tunerStatus()) ?? []
    }

    /// The tuner currently carrying the active channel, if the HDHR reports one.
    func activeTunerStatus() async -> HDHRTunerStatus? {
        let all = await tunerStatus()
        guard let number = player.activeChannel?.guideNumber else { return all.first }
        return all.first { $0.VctNumber == number } ?? all.first { ($0.SignalStrengthPercent ?? 0) > 0 }
    }

    // MARK: - Guide queries for the new screens

    func search(_ query: String) async throws -> [Program] {
        try await epgStore.search(query, from: .now, limit: 150)
    }

    func airings(of program: Program) async throws -> [Program] {
        try await epgStore.airings(
            ofTitle: program.title, excludingID: program.id,
            from: .now, to: .now.addingTimeInterval(7 * 24 * 3600)
        )
    }

    func upNextBatch(for channels: [Channel], at instant: Date = .now) async throws -> [String: Program] {
        let byXmltv = try await epgStore.upNextBatch(channelXmltvIDs: channels.map(\.xmltvID), at: instant)
        var out: [String: Program] = [:]
        for c in channels { if let p = byXmltv[c.xmltvID] { out[c.id] = p } }
        return out
    }

    func programs(inCategoryContaining needle: String, from: Date, to: Date) async throws -> [Program] {
        try await epgStore.programs(inCategoryContaining: needle, from: from, to: to)
    }

    /// Resolve a program row back to the channel it belongs to. Search and
    /// "also airing" results carry only the xmltvID join key.
    func channel(forXmltvID id: String) -> Channel? {
        visibleChannels.first { $0.xmltvID == id } ?? channels.first { $0.xmltvID == id }
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
        // Demo listings are keyed by "demo.<guideNumber>" regardless of the
        // configured guide source, so switching sources (or leaving a stale
        // override behind) can't break the join while demo mode is on.
        if isDemoMode {
            return DemoContent.xmltvID(forGuideNumber: guideNumber)
        }
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

    /// Adjust the user A/V sync trim (milliseconds, positive delays audio) and
    /// apply it to all live players immediately so it can be tuned by ear
    /// during playback.
    func setAudioSyncOffset(millis: Int) {
        let clamped = max(-500, min(500, millis))
        settings.audioSyncOffsetMillis = clamped
        audioMonitor.userOffsetMicros = clamped * 1000
        audioMonitor.recompute(reason: "userTrim")
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
