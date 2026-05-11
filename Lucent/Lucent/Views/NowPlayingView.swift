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

    /// True when the mini-guide should be presented as a modal sheet
    /// (iPhone) rather than as a sibling overlay panel (tvOS / iPad).
    private var miniGuideAsSheet: Bool { metrics.miniGuideWidth == nil }

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

            VLCPlayerView()
                .ignoresSafeArea()

            if overlayVisible {
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
        }
        .contentShape(Rectangle())
        .onAppear {
            #if !os(tvOS)
            appModel.pip.nowPlayingMounted = true
            // Prime the AVSampleBufferDisplayLayer continuously so AVPiP can
            // auto-start from inline when the app backgrounds.
            appModel.pip.startFeeding()
            #endif
            scheduleHide()
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
            #if !os(tvOS)
            appModel.pip.nowPlayingMounted = false
            // Keep VLC alive if PIP is still showing — the frame source needs
            // the player. PIP teardown will run player.tearDown() when it stops.
            if !appModel.pip.isActive {
                appModel.pip.stopFeeding()
                appModel.player.tearDown()
            }
            #else
            appModel.player.tearDown()
            #endif
        }
        #if !os(tvOS)
        .sheet(isPresented: miniGuideSheetBinding) {
            miniGuideOverlayView
                .environment(appModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
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
            HStack(alignment: .top) {
                #if !os(tvOS)
                doneButton
                #endif
                channelChip
                Spacer()
                #if !os(tvOS)
                pipButton
                #endif
                favoriteButton
            }
            Spacer()
            HStack(alignment: .bottom) {
                programChip
                Spacer()
                sleepChip
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
    @ViewBuilder
    private var pipButton: some View {
        if appModel.pip.isSupported, appModel.pip.isPossible {
            Button {
                appModel.pip.toggle()
                showOverlay()
            } label: {
                Image(systemName: appModel.pip.isActive ? "pip.exit" : "pip.enter")
                    .font(.title)
                    .foregroundStyle(GuideTokens.text)
                    .padding(20)
                    .background(Color.black.opacity(0.55), in: .circle)
                    .overlay(Circle().stroke(GuideTokens.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appModel.pip.isActive ? "Exit Picture in Picture" : "Picture in Picture")
        }
    }

    private var doneButton: some View {
        Button {
            appModel.sleepTimer.cancel()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GuideTokens.text)
                .padding(14)
                .background(Color.black.opacity(0.55), in: .circle)
                .overlay(Circle().stroke(GuideTokens.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
    #endif

    private var channelChip: some View {
        HStack(spacing: 12) {
            Text(currentChannel.guideNumber)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(GuideTokens.text)
            Text(currentChannel.guideName)
                .font(.title3.weight(.medium))
                .foregroundStyle(GuideTokens.text2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.55), in: .capsule)
        .overlay(Capsule().stroke(GuideTokens.borderStrong, lineWidth: 1))
    }

    private var programChip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nowPlaying?.title ?? "—")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text)
            if let p = nowPlaying {
                HStack(spacing: 8) {
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
                .foregroundStyle(GuideTokens.text3)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.55), in: .rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(GuideTokens.borderStrong, lineWidth: 1)
        )
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
                .font(.title)
                .foregroundStyle(isFav ? GuideTokens.accent2 : GuideTokens.text)
                .padding(20)
                .background(Color.black.opacity(0.55), in: .circle)
                .overlay(Circle().stroke(GuideTokens.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

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

    private func refreshNowPlaying() async {
        nowPlaying = try? await appModel.nowPlaying(for: currentChannel)
    }
}
