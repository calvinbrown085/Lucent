import SwiftUI
import TVCore

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var testingConnection = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = appModel.settings
        NavigationStack {
            ZStack {
                RadialGradient(
                    colors: [GuideTokens.bgGrad1, GuideTokens.bgGrad2],
                    center: .top,
                    startRadius: 200,
                    endRadius: 1400
                )
                .ignoresSafeArea()

                Form {
                if appModel.isDemoMode {
                    Section("Demo mode") {
                        Label("Demo mode is on", systemImage: "play.tv")
                            .font(.headline)
                        Text("Lucent is showing a sample lineup with a week of listings and a simulated picture. No tuner is contacted and nothing is fetched from the network — everything is generated on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Exit demo mode") {
                            Task { await appModel.exitDemoMode() }
                        }
                    }
                }

                Section("HDHomeRun") {
                    if !appModel.discoveredDevices.isEmpty || appModel.isScanning {
                        Text("Discovered on this network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if appModel.isScanning && appModel.discoveredDevices.isEmpty {
                            HStack {
                                ProgressView()
                                Text("Scanning…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(appModel.discoveredDevices) { device in
                            DiscoveredDeviceRow(device: device, selected: device.host == settings.hdhrIP) {
                                Task { await appModel.selectDiscovered(device) }
                            }
                        }
                        Button {
                            Task { await appModel.scanForDevices() }
                        } label: {
                            HStack {
                                Text("Scan again")
                                if appModel.isScanning && !appModel.discoveredDevices.isEmpty { ProgressView() }
                            }
                        }
                        .disabled(appModel.isScanning)
                    }

                    Text("Or enter IP manually")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Device IP (e.g. 192.168.1.50)", text: $settings.hdhrIP)
                    if !appModel.isDemoMode {
                        Text("No tuner handy? Type “demo” here and tap Test connection to explore Lucent with sample channels and listings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testingConnection { ProgressView() }
                        }
                    }
                    if let device = appModel.device {
                        LabeledContent("Model", value: device.ModelNumber ?? "—")
                        LabeledContent("Firmware", value: device.FirmwareName ?? "—")
                        LabeledContent("Tuners", value: "\(device.TunerCount ?? 0)")
                    }
                    if let result = testResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Guide source") {
                    if appModel.isDemoMode {
                        Text("Demo listings are generated on this device, so the source below is ignored while demo mode is on. “Refresh now” regenerates the sample week.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Source", selection: $settings.guideSource) {
                        ForEach(GuideSource.allCases) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch settings.guideSource {
                    case .gracenote:
                        TextField("Postal code", text: $settings.postalCode)
                        TextField("Country (3-letter, e.g. USA)", text: $settings.countryCode)
                        Button {
                            Task { await appModel.updatePostalCodeFromLocation() }
                        } label: {
                            HStack {
                                Text("Use my location")
                                if appModel.isResolvingLocation { ProgressView() }
                            }
                        }
                        if let err = appModel.locationError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        TextField(
                            "Lineup ID (advanced — leave blank for OTA)",
                            text: $settings.lineupIDOverride
                        )
                        Text("Leave the lineup ID blank to use the over-the-air lineup for your postal code. Cable users can paste a lineup ID looked up from a public TV-listings service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .xmltvURL:
                        TextField("XMLTV URL", text: $settings.xmltvURLString)
                    }

                    Button {
                        Task { await appModel.refreshGuide() }
                    } label: {
                        HStack {
                            Text("Refresh now")
                            if appModel.isRefreshingEPG { ProgressView() }
                        }
                    }
                    if let last = appModel.lastEPGRefresh {
                        LabeledContent("Last refresh", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Section("Playback") {
                    Picker(
                        "Prewarm channels",
                        selection: Binding(
                            get: { settings.prewarmCount },
                            set: { appModel.setPrewarmCount($0) }
                        )
                    ) {
                        ForEach(0...2, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Each prewarmed channel uses one HDHomeRun tuner. Lower this if streams stall.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Audio sync")
                        Spacer()
                        Button {
                            appModel.setAudioSyncOffset(millis: settings.audioSyncOffsetMillis - 25)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(settings.audioSyncOffsetMillis <= -500)
                        Text(audioSyncLabel)
                            .monospacedDigit()
                            .frame(minWidth: 90)
                            .foregroundStyle(.secondary)
                        Button {
                            appModel.setAudioSyncOffset(millis: settings.audioSyncOffsetMillis + 25)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(settings.audioSyncOffsetMillis >= 500)
                    }
                    if settings.audioSyncOffsetMillis != 0 {
                        Button("Reset audio sync") {
                            appModel.setAudioSyncOffset(millis: 0)
                        }
                    }
                    Text("If voices land before lips move, tap + to delay audio until they match. Takes effect immediately during playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Channels") {
                    NavigationLink {
                        ManageChannelsView()
                    } label: {
                        HStack {
                            Text("Manage channels")
                            Spacer()
                            if !settings.hiddenChannels.isEmpty {
                                Text("\(settings.hiddenChannels.count) hidden")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Channel mapping") {
                    if appModel.channels.isEmpty {
                        Text("Channels will appear here after a successful connection.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.channels) { channel in
                            ChannelMappingRow(channel: channel)
                        }
                    }
                }

                if let err = appModel.bootstrapError {
                    Section {
                        Text(err).foregroundStyle(GuideTokens.live)
                    }
                }

                Section("About") {
                    NavigationLink("Acknowledgments") {
                        AcknowledgmentsView()
                    }
                }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.hdhrIP) { _, newValue in
                // Typing `demo` into the address field is the whole gesture —
                // don't make the user find "Test connection" too. The reverse
                // isn't watched here: mid-edit values like "dem" would fire a
                // pointless bootstrap against a bogus host. Leaving demo mode
                // happens on the next bootstrap (Test connection, Exit demo
                // mode, or relaunch), which purges the sample listings.
                guard DemoContent.isDemoAddress(newValue), !appModel.isDemoLoaded else { return }
                testResult = nil
                Task { await appModel.bootstrap() }
            }
            .onChange(of: settings.guideSource) { _, _ in
                // The EPG join key (xmltvID) depends on the active source —
                // Gracenote keys by guideNumber, XMLTV by guideName. Re-resolve
                // immediately so the guide doesn't query with stale keys until
                // the next manual refresh.
                appModel.rebuildChannelMapping()
            }
            .task {
                guard !appModel.isDemoMode else { return }
                if appModel.discoveredDevices.isEmpty && !appModel.isScanning {
                    await appModel.scanForDevices()
                }
            }
        }
    }

    private var audioSyncLabel: String {
        let millis = appModel.settings.audioSyncOffsetMillis
        return millis > 0 ? "+\(millis) ms" : "\(millis) ms"
    }

    private func testConnection() async {
        testingConnection = true
        testResult = nil
        defer { testingConnection = false }
        await appModel.bootstrap()
        if appModel.isDemoMode {
            testResult = "Demo mode on — \(appModel.channels.count) sample channels loaded."
        } else if let device = appModel.device {
            testResult = "Connected to \(device.ModelNumber ?? "device") (\(device.DeviceID))."
        } else if let err = appModel.bootstrapError {
            testResult = "Failed: \(err)"
        }
    }
}

private struct DiscoveredDeviceRow: View {
    let device: HDHRDiscoveredDevice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.info.ModelNumber ?? "HDHomeRun")
                        .font(.headline)
                    Text("\(device.host) · \(device.info.DeviceID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

private struct ChannelMappingRow: View {
    let channel: Channel
    @Environment(AppModel.self) private var appModel
    @State private var override: String = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(channel.guideNumber) · \(channel.guideName)")
                Text("xmltvID: \(channel.xmltvID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Override xmltvID", text: $override)
                .frame(maxWidth: 360)
                .onSubmit {
                    appModel.setXMLTVOverride(channelID: channel.id, xmltvID: override)
                }
        }
        .onAppear {
            override = appModel.settings.xmltvOverrides[channel.id] ?? ""
        }
    }
}
