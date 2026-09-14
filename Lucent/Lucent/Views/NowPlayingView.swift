import SwiftUI
import TVCore

struct NowPlayingView: View {
    let channel: Channel
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutMetrics) private var metrics
    @State private var nowPlaying: Program?
    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var miniGuideOpen = false
    @State private var miniGuideHideTask: Task<Void, Never>?
    @State private var sleepDialogPresented = false
    @State private var captionsDialogPresented = false
    @State private var audioDialogPresented = false
    @State private var numberPadOpen = false
    @State private var numberEntry = ""
    @State private var signal: HDHRTunerStatus?
    @State private var signalTask: Task<Void, Never>?

    /// True when the mini-guide should be presented as a modal sheet
    /// (iPhone) rather than as a sibling overlay panel (tvOS / iPad).
    private var miniGuideAsSheet: Bool { metrics.miniGuideWidth == nil }

    /// iPhone: chips don't fit in one row, so the overlay stacks — channel
    /// row on top, program chip full width, tools in a scrolling strip.
    private var compactOverlay: Bool { metrics.miniGuideWidth == nil }

    private var miniGuideSheetBinding: Binding<Bool> {
        Binding(
            get: { miniGuideOpen && miniGuideAsSheet },
            set: { newValue in
                if !newValue { closeMiniGuide() }
            }
        )
    }

    /// Mini-guide auto-hide window. Longer than the bottom overlay's 3s because
    /// the user is actively browsing.
    private static let miniGuideAutoHideSeconds: UInt64 = 8

    /// Sleep timer durations offered in the chip's confirmation dialog. Add a
    /// 1-minute entry in DEBUG builds so the warning + expiry path is testable
    /// without sitting through 14 minutes.
    private var sleepDurationOptions: [Int] {
        #if DEBUG
        return [1, 15, 30, 60, 90]
        #else
        return [15, 30, 60, 90]
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LiveVideoLayer(channel: currentChannel, program: nowPlaying)
                .ignoresSafeArea()

            if overlayVisible, !numberPadOpen {
                overlay
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            #if os(tvOS)
            if miniGuideOpen {
                miniGuideOverlayView
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .zIndex(1)
            }
            #else
            // iPad: render as sibling overlay panel (matches tvOS).
            // iPhone: presented via .sheet below — skip inline rendering.
            if miniGuideOpen, !miniGuideAsSheet {
                miniGuideOverlayView
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .zIndex(1)
            }
            #endif

            if appModel.sleepTimer.isWarning {
                sleepWarningOverlay
                    .transition(.opacity)
                    .zIndex(2)
            }

            if numberPadOpen, !miniGuideAsSheet {
                numberPad
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(3)
            }
        }
        .contentShape(Rectangle())
        #if os(tvOS)
        // With the chips hidden nothing on screen is focusable, so a Select
        // press would go nowhere. Make the root itself focusable in that
        // state; the tap handler below then brings the overlay back.
        .focusable(!overlayVisible && !miniGuideOpen && !numberPadOpen)
        #endif
        .onAppear {
            appModel.isFullscreenPresented = true
            #if !os(tvOS)
            appModel.pip.inAppVideoMounted = true
            #endif
            scheduleHide()
            startSignalPolling()
        }
        .onChange(of: overlayVisible) { _, visible in
            if visible { startSignalPolling() } else { stopSignalPolling() }
        }
        #if os(tvOS)
        // Play/Pause on the Siri Remote is the classic "last channel" key.
        .onPlayPauseCommand {
            if numberPadOpen { return }
            appModel.tuneToPreviousChannel()
            showOverlay()
        }
        #endif
        // Hardware keyboard / remote keypad digits open direct entry.
        .onKeyPress(characters: .decimalDigits) { press in
            numberEntry = numberPadOpen ? numberEntry + press.characters : press.characters
            openNumberPad()
            return .handled
        }
        .onChange(of: appModel.player.activeChannel?.id) { _, _ in
            // New channel => refresh overlay info and re-show.
            Task { await refreshNowPlaying() }
            showOverlay()
        }
        .onChange(of: appModel.sleepTimerDidExpire) { _, expired in
            if expired {
                appModel.sleepTimerDidExpire = false
                dismiss()
            }
        }
        .task {
            await refreshNowPlaying()
        }
        #if os(tvOS)
        .onMoveCommand { direction in
            handleMove(direction)
        }
        .onExitCommand {
            handleExit()
        }
        #else
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    handleSwipe(translation: value.translation)
                }
        )
        #endif
        .onTapGesture {
            if appModel.sleepTimer.isWarning {
                appModel.sleepTimer.dismissWarning()
                showOverlay()
                return
            }
            if overlayVisible {
                hideOverlay()
            } else {
                showOverlay()
            }
        }
        .onDisappear {
            stopSignalPolling()
            appModel.isFullscreenPresented = false
            // On iPad the picture drops back into the docked pane instead
            // of stopping; everywhere else closing Now Playing ends playback —
            // unless PiP has the stream, in which case PiP's stop tears down.
            #if !os(tvOS)
            appModel.pip.inAppVideoMounted = appModel.prefersDockedPlayback
            if appModel.pip.isActive { return }
            #endif
            if !appModel.prefersDockedPlayback {
                appModel.player.tearDown()
            }
        }
        #if !os(tvOS)
        .sheet(isPresented: miniGuideSheetBinding) {
            miniGuideOverlayView
                .environment(appModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { numberPadOpen && miniGuideAsSheet },
            set: { if !$0 { closeNumberPad() } }
        )) {
            numberPad
                .padding()
                .presentationDetents([.large])
        }
        #endif
    }

    private var numberPad: some View {
        ChannelNumberPad(
            entry: $numberEntry,
            channels: appModel.visibleChannels,
            onTune: { ch in
                appModel.tune(to: ch)
                closeNumberPad()
                showOverlay()
            },
            onClose: { closeNumberPad() }
        )
        .frame(maxWidth: 720)
        #if os(tvOS)
        .onExitCommand { closeNumberPad() }
        #endif
    }

    private func openNumberPad() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            overlayVisible = true
            numberPadOpen = true
        }
    }

    private func closeNumberPad() {
        withAnimation(.easeInOut(duration: 0.2)) { numberPadOpen = false }
        numberEntry = ""
        showOverlay()
    }

    // MARK: - Signal

    /// Poll the tuner's signal readings while the overlay is up. Two seconds
    /// matches the HDHR web UI's own refresh cadence.
    private func startSignalPolling() {
        guard signalTask == nil else { return }
        signalTask = Task { @MainActor in
            while !Task.isCancelled {
                signal = await appModel.activeTunerStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopSignalPolling() {
        signalTask?.cancel()
        signalTask = nil
    }

    private var miniGuideOverlayView: some View {
        MiniGuideOverlay(
            activeChannelID: appModel.player.activeChannel?.id ?? channel.id,
            onTune: { selected in
                appModel.tune(to: selected)
                closeMiniGuide()
            },
            onClose: { closeMiniGuide() }
        )
    }

    #if os(tvOS)
    private func handleMove(_ direction: MoveCommandDirection) {
        if appModel.sleepTimer.isWarning {
            appModel.sleepTimer.dismissWarning()
            showOverlay()
            return
        }
        if numberPadOpen { return }
        if miniGuideOpen {
            if direction == .left {
                closeMiniGuide()
                return
            }
            resetMiniGuideAutoHide()
            return
        }
        switch direction {
        case .up:
            appModel.tuneAdjacent(offset: -1)
        case .down:
            appModel.tuneAdjacent(offset: 1)
        case .right:
            openMiniGuide()
            return
        default:
            break
        }
        showOverlay()
    }

    private func handleExit() {
        if numberPadOpen {
            closeNumberPad()
            return
        }
        if miniGuideOpen {
            closeMiniGuide()
            return
        }
        appModel.sleepTimer.cancel()
        dismiss()
    }
    #else
    private func handleSwipe(translation: CGSize) {
        if appModel.sleepTimer.isWarning {
            appModel.sleepTimer.dismissWarning()
            showOverlay()
            return
        }
        let dx = translation.width
        let dy = translation.height
        let absX = abs(dx)
        let absY = abs(dy)

        if miniGuideOpen {
            if dx < -30 {
                closeMiniGuide()
            } else {
                resetMiniGuideAutoHide()
            }
            return
        }

        if absX > absY {
            if dx > 50 {
                openMiniGuide()
                return
            } else if dx < -50 {
                // Swipe-left with no mini-guide: no-op for now.
                showOverlay()
                return
            }
        } else {
            if dy < -50 {
                appModel.tuneAdjacent(offset: -1)
            } else if dy > 120 {
                // Strong swipe down dismisses Now Playing.
                appModel.sleepTimer.cancel()
                dismiss()
                return
            } else if dy > 50 {
                appModel.tuneAdjacent(offset: 1)
            }
        }
        showOverlay()
    }
    #endif

    private var currentChannel: Channel {
        appModel.player.activeChannel ?? channel
    }

    @ViewBuilder
    private var overlay: some View {
        VStack {
            HStack(alignment: .center, spacing: compactOverlay ? 10 : 14) {
                #if !os(tvOS)
                doneButton
                #endif
                channelChip
                    .fixedSize()
                if !compactOverlay, let prev = appModel.previousChannel {
                    previousChannelChip(prev)
                }
                Spacer(minLength: 8)
                if !compactOverlay, let signal {
                    SignalChip(status: signal)
                }
                #if !os(tvOS)
                pipButton
                #endif
                favoriteButton
            }
            Spacer()
            if compactOverlay {
                VStack(alignment: .leading, spacing: 10) {
                    programChip
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            if let prev = appModel.previousChannel {
                                previousChannelChip(prev)
                            }
                            if let signal {
                                SignalChip(status: signal, compact: true)
                            }
                            captionsChip
                            audioChip
                            goToChip
                            sleepChip
                        }
                        .fixedSize()
                    }
                    .scrollClipDisabled()
                }
            } else {
                HStack(alignment: .bottom, spacing: 14) {
                    programChip
                    Spacer()
                    captionsChip
                    audioChip
                    goToChip
                    sleepChip
                }
            }
        }
        .padding(metrics.contentHorizontalPadding)
        .padding(.trailing, sidePanelInset)
        .animation(.easeInOut(duration: 0.25), value: miniGuideOpen)
    }

    private var sidePanelInset: CGFloat {
        guard miniGuideOpen, let panelWidth = metrics.miniGuideWidth else { return 0 }
        return panelWidth
    }

    #if !os(tvOS)
    private var doneButton: some View {
        Button {
            appModel.sleepTimer.cancel()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GuideTokens.text)
                .padding(14)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
    #endif

    private var channelChip: some View {
        HStack(spacing: compactOverlay ? 8 : 12) {
            Text(currentChannel.guideNumber)
                .font(.system(size: compactOverlay ? 22 : 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text)
            Text(currentChannel.guideName)
                .font(compactOverlay ? .subheadline.weight(.medium) : .title3.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text2)
        }
        .padding(.horizontal, compactOverlay ? 14 : 24)
        .padding(.vertical, compactOverlay ? 10 : 14)
        // One glass material across every overlay chip — this is the app's
        // navigation layer, where Liquid Glass belongs (never on content).
        .glassEffect(.regular, in: .capsule)
    }

    private var programChip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nowPlaying?.title ?? "—")
                .font(compactOverlay ? .headline : .title2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text)
            if let p = nowPlaying {
                HStack(spacing: 8) {
                    if p.isLive {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .tracking(0.8)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(GuideTokens.live, in: .capsule)
                            .foregroundStyle(.white)
                    }
                    Text(p.start, format: .dateTime.hour().minute())
                    Text("–")
                    Text(p.stop, format: .dateTime.hour().minute())
                    if let s = p.subtitle, !s.isEmpty {
                        Text("•")
                        Text(s).lineLimit(1)
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(GuideTokens.text3)
                ProgressView(value: progress(of: p))
                    .tint(GuideTokens.accent)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: compactOverlay ? .infinity : 700, alignment: .leading)
        .padding(.horizontal, compactOverlay ? 16 : 24)
        .padding(.vertical, compactOverlay ? 12 : 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func previousChannelChip(_ prev: Channel) -> some View {
        Button {
            appModel.tuneToPreviousChannel()
            showOverlay()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                Text(prev.guideNumber)
                    .monospacedDigit()
            }
            .font(.headline)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Back to channel \(prev.guideNumber) \(prev.guideName)")
    }

    private var captionsChip: some View {
        let on = appModel.player.captionsOn || (appModel.settings.captionsEnabled && appModel.player.subtitleTracks.isEmpty)
        return Button {
            appModel.player.refreshTracks()
            if appModel.player.subtitleTracks.filter({ $0.id >= 0 }).count > 1 {
                captionsDialogPresented = true
            } else {
                appModel.toggleCaptions()
            }
            showOverlay()
        } label: {
            Image(systemName: on ? "captions.bubble.fill" : "captions.bubble")
                .font(.headline)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(on ? "Captions on" : "Captions off")
        .confirmationDialog("Captions", isPresented: $captionsDialogPresented, titleVisibility: .visible) {
            ForEach(appModel.player.subtitleTracks) { track in
                Button(track.id < 0 ? "Off" : track.name) {
                    appModel.player.selectSubtitleTrack(track.id)
                    appModel.settings.captionsEnabled = track.id >= 0
                    showOverlay()
                }
            }
            Button("Dismiss", role: .cancel) {}
        }
    }

    private var audioChip: some View {
        Button {
            appModel.player.refreshTracks()
            audioDialogPresented = true
            showOverlay()
        } label: {
            Image(systemName: "waveform")
                .font(.headline)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Audio track")
        .confirmationDialog("Audio", isPresented: $audioDialogPresented, titleVisibility: .visible) {
            if appModel.player.audioTracks.isEmpty {
                Button("Only one audio track") {}
            }
            ForEach(appModel.player.audioTracks.filter { $0.id >= 0 }) { track in
                Button(track.id == appModel.player.currentAudioTrackID ? "✓ \(track.name)" : track.name) {
                    appModel.player.selectAudioTrack(track.id)
                    showOverlay()
                }
            }
            Button("Dismiss", role: .cancel) {}
        }
    }

    private var goToChip: some View {
        Button {
            openNumberPad()
        } label: {
            Image(systemName: "number")
                .font(.headline)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Go to channel")
    }

    private var sleepChip: some View {
        Button {
            sleepDialogPresented = true
            showOverlay()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: appModel.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                Text(sleepChipLabel)
                    .monospacedDigit()
            }
            .font(.headline)
        }
        .buttonStyle(.glass)
        .confirmationDialog(
            "Sleep timer",
            isPresented: $sleepDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(sleepDurationOptions, id: \.self) { mins in
                Button(label(for: mins)) {
                    appModel.sleepTimer.start(minutes: mins)
                    showOverlay()
                }
            }
            if appModel.sleepTimer.isActive {
                Button("Cancel timer", role: .destructive) {
                    appModel.sleepTimer.cancel()
                    showOverlay()
                }
            }
            Button("Dismiss", role: .cancel) {}
        }
    }

    private var sleepChipLabel: String {
        if appModel.sleepTimer.isActive {
            return "Sleep · \(formatRemaining(appModel.sleepTimer.secondsRemaining))"
        }
        return "Sleep"
    }

    private func label(for minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes == 60 { return "1 hour" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func formatRemaining(_ seconds: Int) -> String {
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private var favoriteButton: some View {
        let isFav = appModel.isFavorite(currentChannel)
        return Button {
            appModel.toggleFavorite(currentChannel)
            showOverlay()
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(compactOverlay ? .title3 : .title)
                .foregroundStyle(isFav ? GuideTokens.accent2 : GuideTokens.text)
                .padding(compactOverlay ? 14 : 20)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
    }

    #if !os(tvOS)
    @ViewBuilder
    private var pipButton: some View {
        if appModel.pip.isSupported, appModel.settings.pipEnabled {
            Button {
                appModel.pip.toggle()
                showOverlay()
            } label: {
                Image(systemName: appModel.pip.isActive ? "pip.exit" : "pip.enter")
                    .font(compactOverlay ? .title3 : .title)
                    .foregroundStyle(appModel.pip.isPossible ? GuideTokens.text : GuideTokens.text4)
                    .padding(compactOverlay ? 14 : 20)
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!appModel.pip.isPossible)
            .accessibilityLabel(appModel.pip.isActive ? "Exit Picture in Picture" : "Picture in Picture")
        }
    }
    #endif

    private var sleepWarningOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 56))
                .foregroundStyle(GuideTokens.accent2)
            Text("Still watching?")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(GuideTokens.text)
            Text("Stops in \(appModel.sleepTimer.secondsRemaining)s — press any button to keep watching.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(GuideTokens.text2)
                .monospacedDigit()
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 48)
        .background(Color.black.opacity(0.78), in: .rect(cornerRadius: 32))
        .overlay(
            RoundedRectangle(cornerRadius: 32)
                .stroke(GuideTokens.borderStrong, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35).ignoresSafeArea())
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !miniGuideOpen else { return }
        #if DEBUG
        // Screenshot hook: LUCENT_KEEP_OVERLAY=1 pins the chrome on screen.
        if ProcessInfo.processInfo.environment["LUCENT_KEEP_OVERLAY"] != nil { return }
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.25)) { overlayVisible = false }
            }
        }
    }

    private func showOverlay() {
        withAnimation(.easeInOut(duration: 0.2)) { overlayVisible = true }
        scheduleHide()
    }

    private func hideOverlay() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { overlayVisible = false }
    }

    private func openMiniGuide() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            miniGuideOpen = true
        }
        resetMiniGuideAutoHide()
    }

    private func closeMiniGuide() {
        miniGuideHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            miniGuideOpen = false
        }
        showOverlay()
    }

    private func resetMiniGuideAutoHide() {
        miniGuideHideTask?.cancel()
        miniGuideHideTask = Task {
            try? await Task.sleep(for: .seconds(Self.miniGuideAutoHideSeconds))
            if !Task.isCancelled, miniGuideOpen {
                closeMiniGuide()
            }
        }
    }

    private func progress(of p: Program) -> Double {
        let total = p.stop.timeIntervalSince(p.start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date.now.timeIntervalSince(p.start) / total))
    }

    private func refreshNowPlaying() async {
        nowPlaying = try? await appModel.nowPlaying(for: currentChannel)
    }
}


// MARK: - Signal chip

/// Compact signal meter for the active tuner. Strength/quality are the two
/// numbers that matter for an antenna: strength is raw RF, quality is what
/// the decoder can actually use. Colour follows the worse of the two.
struct SignalChip: View {
    let status: HDHRTunerStatus
    var compact: Bool = false

    private var strength: Int { status.SignalStrengthPercent ?? 0 }
    private var quality: Int { status.SignalQualityPercent ?? 0 }
    private var worst: Int { min(strength, quality) }

    private var tint: Color {
        if worst >= 70 { return Color(hex: 0x3DDC84) }
        if worst >= 45 { return GuideTokens.accent2 }
        return GuideTokens.live
    }

    private var bars: Int {
        switch worst {
        case 80...: return 4
        case 60..<80: return 3
        case 40..<60: return 2
        case 1..<40: return 1
        default: return 0
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < bars ? tint : Color.white.opacity(0.18))
                        .frame(width: 5, height: CGFloat(6 + i * 4))
                }
            }
            if compact {
                Text("\(quality)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(GuideTokens.text2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Signal \(strength)%")
                    Text("Quality \(quality)%")
                }
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(GuideTokens.text2)
            }
        }
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Signal strength \(strength) percent, quality \(quality) percent")
    }
}
