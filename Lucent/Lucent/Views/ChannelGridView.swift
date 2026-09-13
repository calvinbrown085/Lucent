import SwiftUI
import TVCore

struct ChannelGridView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics
    @State private var presentedChannel: Channel?
    @State private var detailProgram: Program?
    @State private var onNow: [String: Program] = [:]
    @State private var upNext: [String: Program] = [:]

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 32),
            count: metrics.channelGridColumns
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RadialGradient(
                    colors: [GuideTokens.bgGrad1, GuideTokens.bgGrad2],
                    center: .top,
                    startRadius: 200,
                    endRadius: 1400
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 48) {
                        if !railChannels.isEmpty {
                            rail(title: "On Now", subtitle: railSubtitle, programs: onNow, isUpNext: false)
                            if !upNext.isEmpty {
                                rail(title: "Up Next", subtitle: nil, programs: upNext, isUpNext: true)
                            }
                        }
                        if !appModel.favoriteChannels.isEmpty {
                            section(title: "Favorites", channels: appModel.favoriteChannels)
                        }
                        section(title: "All Channels", channels: appModel.visibleChannels)
                        if appModel.visibleChannels.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, metrics.contentHorizontalPadding)
                    .padding(.vertical, 60)
                }
            }
            .navigationTitle("Lucent")
            .fullScreenCover(item: $presentedChannel) { channel in
                NowPlayingView(channel: channel)
                    .environment(appModel)
            }
            .sheet(item: $detailProgram) { program in
                ProgramDetailView(program: program)
                    .environment(appModel)
            }
            .task(id: RailKey(channelIDs: railChannels.map(\.id), refresh: appModel.lastEPGRefresh)) {
                await loadRails()
            }
        }
    }

    private struct RailKey: Hashable {
        let channelIDs: [String]
        let refresh: Date?
    }

    /// Favorites drive the rails; with none set, fall back to the first
    /// dozen visible channels so the screen still opens on something.
    private var railChannels: [Channel] {
        let favs = appModel.favoriteChannels
        return favs.isEmpty ? Array(appModel.visibleChannels.prefix(12)) : favs
    }

    private var railSubtitle: String? {
        appModel.favoriteChannels.isEmpty ? "Star channels to pick what shows here" : nil
    }

    private func loadRails() async {
        let channels = railChannels
        async let now = appModel.nowPlayingBatch(for: channels)
        async let next = appModel.upNextBatch(for: channels)
        onNow = (try? await now) ?? [:]
        upNext = (try? await next) ?? [:]
    }

    @ViewBuilder
    private func rail(title: String, subtitle: String?, programs: [String: Program], isUpNext: Bool) -> some View {
        let entries = railChannels.compactMap { ch in programs[ch.id].map { (channel: ch, program: $0) } }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(GuideTokens.text3)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(GuideTokens.text4)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 28) {
                        ForEach(entries, id: \.channel.id) { entry in
                            RailCard(channel: entry.channel, program: entry.program, isUpNext: isUpNext) {
                                if isUpNext {
                                    detailProgram = entry.program
                                } else {
                                    appModel.tune(to: entry.channel)
                                    if !appModel.prefersDockedPlayback { presentedChannel = entry.channel }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 12)
                }
                .padding(.horizontal, -12)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, channels: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(GuideTokens.text3)
            LazyVGrid(columns: columns, spacing: 32) {
                ForEach(channels) { channel in
                    ChannelCard(channel: channel) {
                        appModel.tune(to: channel)
                        if !appModel.prefersDockedPlayback { presentedChannel = channel }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 80))
                .foregroundStyle(GuideTokens.text3)
            if appModel.isScanning {
                ProgressView()
                Text("Looking for HDHomeRun on your network…")
                    .foregroundStyle(GuideTokens.text2)
            } else {
                Text("No channels yet")
                    .font(.title3)
                    .foregroundStyle(GuideTokens.text)
                if let err = appModel.bootstrapError {
                    Text(err)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GuideTokens.text3)
                        .padding(.horizontal, 32)
                } else {
                    Text("Open Settings and enter your HDHomeRun's IP address.")
                        .foregroundStyle(GuideTokens.text2)
                    Text("No tuner? Enter “demo” there for a sample lineup.")
                        .font(.footnote)
                        .foregroundStyle(GuideTokens.text3)
                }
                Button {
                    Task { await appModel.bootstrap() }
                } label: {
                    Text("Try again")
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct NowPlayingKey: Hashable {
    let channelID: String
    let epgRefresh: Date?
}

private struct ChannelCard: View {
    let channel: Channel
    let action: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var nowPlaying: Program?

    #if os(tvOS)
    @Environment(\.isFocused) private var environmentFocused
    private var isHighlighted: Bool { environmentFocused }
    #else
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    private var isHighlighted: Bool { isHovered || isPressed }
    #endif

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(channel.guideNumber)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(GuideTokens.text)
                    Spacer()
                    HStack(alignment: .center, spacing: 8) {
                        if appModel.isFavorite(channel) {
                            Image(systemName: "star.fill")
                                .font(.callout)
                                .foregroundStyle(GuideTokens.accent2)
                        }
                        if channel.isHD {
                            Text("HD")
                                .font(.caption.weight(.heavy))
                                .tracking(0.6)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(GuideTokens.accent.opacity(0.18), in: .rect(cornerRadius: 6))
                                .foregroundStyle(GuideTokens.accent2)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
                Text(channel.guideName)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(GuideTokens.text2)
                Text(nowPlaying?.title ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(GuideTokens.text3)
                    .lineLimit(1)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(GuideTokens.surface, in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isHighlighted ? GuideTokens.focusRing : GuideTokens.border,
                        lineWidth: isHighlighted ? 2 : 1
                    )
            )
            .shadow(
                color: isHighlighted ? .black.opacity(0.5) : .clear,
                radius: isHighlighted ? 24 : 0,
                x: 0,
                y: isHighlighted ? 16 : 0
            )
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(PressTrackingButtonStyle { isPressed = $0 })
        #endif
        .scaleEffect(isHighlighted ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        #endif
        // Keyed on the last refresh too, so a card rendered before the guide
        // finished loading fills in its program title instead of staying blank.
        .task(id: NowPlayingKey(channelID: channel.id, epgRefresh: appModel.lastEPGRefresh)) {
            nowPlaying = try? await appModel.nowPlaying(for: channel)
        }
    }
}


// MARK: - Rail card

private struct RailCard: View {
    let channel: Channel
    let program: Program
    let isUpNext: Bool
    let action: () -> Void

    #if os(tvOS)
    @Environment(\.isFocused) private var focused
    #else
    @State private var hovered = false
    private var focused: Bool { hovered }
    #endif

    private var progress: Double {
        let total = program.stop.timeIntervalSince(program.start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date.now.timeIntervalSince(program.start) / total))
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(ProgramType.from(program).gradient)
                    HStack(spacing: 8) {
                        Text(channel.guideNumber)
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text(channel.guideName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        if program.isLive {
                            Text("LIVE")
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(0.8)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(GuideTokens.live, in: .rect(cornerRadius: 3))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                }
                .frame(height: 110)

                VStack(alignment: .leading, spacing: 6) {
                    Text(program.title)
                        .font(.headline)
                        .foregroundStyle(GuideTokens.text)
                        .lineLimit(1)
                    Text(isUpNext
                         ? "Starts \(program.start.formatted(.dateTime.hour().minute()))"
                         : (program.subtitle?.isEmpty == false ? program.subtitle! : "Until \(program.stop.formatted(.dateTime.hour().minute()))"))
                        .font(.subheadline)
                        .foregroundStyle(GuideTokens.text3)
                        .lineLimit(1)
                    if !isUpNext {
                        ProgressView(value: progress)
                            .tint(GuideTokens.accent)
                    }
                }
                .padding(14)
            }
            .frame(width: 300)
            .background(GuideTokens.surface, in: .rect(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(focused ? GuideTokens.focusRing : GuideTokens.border, lineWidth: focused ? 2 : 1)
            )
            .shadow(color: focused ? .black.opacity(0.5) : .clear, radius: 20, x: 0, y: 14)
        }
        .buttonStyle(.plain)
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focused)
        #if !os(tvOS)
        .onHover { hovered = $0 }
        #endif
    }
}
