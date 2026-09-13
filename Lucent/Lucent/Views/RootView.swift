import SwiftUI
import TVCore

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        @Bindable var model = appModel
        #if os(tvOS)
        chrome(metrics: resolvedMetrics)
            .tint(GuideTokens.accent)
            .environment(\.layoutMetrics, resolvedMetrics)
            .fullScreenCover(item: $model.pendingTuneChannel) { channel in
                NowPlayingView(channel: channel)
                    .environment(appModel)
            }
        #else
        GeometryReader { geo in
            let metrics = resolvedMetrics.adapted(toContainerWidth: geo.size.width - dockWidth(resolvedMetrics))
            chrome(metrics: metrics)
                .tint(GuideTokens.accent)
                .environment(\.layoutMetrics, metrics)
                .onAppear { appModel.dockedPlayerLayout = metrics.supportsDockedPlayer }
                .onChange(of: metrics.supportsDockedPlayer) { _, supports in
                    appModel.dockedPlayerLayout = supports
                }
        }
        .fullScreenCover(item: $model.pendingTuneChannel) { channel in
            NowPlayingView(channel: channel)
                .environment(appModel)
        }
        .onOpenURL { url in appModel.handle(url: url) }
        #endif
    }

    /// Tabs plus the two root-level sibling layers: the iPad docked player
    /// and the reminder banner. Both are siblings of the tab content, never
    /// wrappers, so VLC's drawable is never inside an effect view.
    @ViewBuilder
    private func chrome(metrics: LayoutMetrics) -> some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                tabs
                if appModel.dockedPlayerVisible {
                    DockedPlayerPane()
                        .frame(width: metrics.dockedPlayerWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appModel.dockedPlayerVisible)

            if FeatureFlags.reminders, let alert = appModel.reminders.activeAlert {
                ReminderBanner(
                    reminder: alert,
                    onWatch: {
                        appModel.reminders.dismissAlert()
                        appModel.watch(channelID: alert.channelID)
                    },
                    onDismiss: { appModel.reminders.dismissAlert() }
                )
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appModel.reminders.activeAlert?.id)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: appModel.sceneDidEnterBackground()
            case .active: appModel.sceneDidBecomeActive()
            default: break
            }
        }
    }

    private func dockWidth(_ metrics: LayoutMetrics) -> CGFloat {
        appModel.dockedPlayerVisible ? metrics.dockedPlayerWidth : 0
    }

    private var tabs: some View {
        TabView {
            Tab("Guide", systemImage: "calendar.day.timeline.left") {
                GuideView()
            }
            Tab("Channels", systemImage: "tv") {
                ChannelGridView()
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }

    private var resolvedMetrics: LayoutMetrics {
        #if os(tvOS)
        return .tvOS
        #else
        var metrics = LayoutMetrics.resolve(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        // The grid is the default everywhere now; the timeline list is an
        // opt-in for phones.
        if metrics.compactGuide, appModel.settings.preferTimelineGuide {
            metrics.useTimelineGuide = true
        }
        return metrics
        #endif
    }
}

// MARK: - Docked player (iPad)

/// Persistent right-hand column on iPad: the live picture, what's on, and a
/// way to go fullscreen. Mounts `VLCPlayerView`, which reparents the single
/// drawable host — the guide hero hides its own preview while this is up.
struct DockedPlayerPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var nowPlaying: Program?

    var body: some View {
        VStack(spacing: 0) {
            if let channel = appModel.player.activeChannel {
                LiveVideoLayer(channel: channel, program: nowPlaying, compact: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .id(channel.id)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(channel.guideNumber)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(GuideTokens.text)
                        Text(channel.guideName)
                            .font(.headline)
                            .foregroundStyle(GuideTokens.text2)
                            .lineLimit(1)
                        Spacer()
                    }
                    Text(nowPlaying?.title ?? "—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GuideTokens.text)
                        .lineLimit(2)
                    if let p = nowPlaying {
                        HStack(spacing: 6) {
                            Text(p.start, format: .dateTime.hour().minute())
                            Text("–")
                            Text(p.stop, format: .dateTime.hour().minute())
                        }
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(GuideTokens.text3)
                        if let d = p.desc, !d.isEmpty {
                            Text(d)
                                .font(.caption)
                                .foregroundStyle(GuideTokens.text3)
                                .lineLimit(3)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            appModel.pendingTuneChannel = channel
                        } label: {
                            Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            appModel.tuneAdjacent(offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.glass)
                        Button {
                            appModel.tuneAdjacent(offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.glass)
                        Button {
                            appModel.player.tearDown()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Stop")
                    }
                    .padding(.top, 6)
                }
                .padding(.top, 14)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GuideTokens.bg)
        .overlay(alignment: .leading) {
            Rectangle().fill(GuideTokens.border).frame(width: 1)
        }
        .task(id: appModel.player.activeChannel?.id) {
            guard let ch = appModel.player.activeChannel else { nowPlaying = nil; return }
            nowPlaying = try? await appModel.nowPlaying(for: ch)
        }
    }
}
