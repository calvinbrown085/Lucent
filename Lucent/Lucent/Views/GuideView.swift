import SwiftUI
import TVCore

// MARK: - Tokens

enum GuideTokens {
    static let columnWidth: CGFloat = 200       // px per 30-min slot
    static let rowHeight: CGFloat = 88
    static let rowGap: CGFloat = 8
    static let channelRailWidth: CGFloat = 240
    static let visibleSlots: Int = 8            // 4 hours
    static let visibleRows: Int = 8
    static let pxPerMinute: CGFloat = columnWidth / 30
    static let stagePadding: CGFloat = 80

    static let heroHeight: CGFloat = 280
    static let heroArtSize = CGSize(width: 360, height: 220)

    static let bg = Color(hex: 0x0A0A0C)
    static let bgGrad1 = Color(hex: 0x14141A)
    static let bgGrad2 = Color(hex: 0x050507)
    static let surface = Color.white.opacity(0.06)
    static let surface2 = Color.white.opacity(0.10)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.18)
    static let text = Color(hex: 0xF5F5F7)
    static let text2 = Color(hex: 0xF5F5F7).opacity(0.72)
    static let text3 = Color(hex: 0xF5F5F7).opacity(0.50)
    static let text4 = Color(hex: 0xF5F5F7).opacity(0.32)
    static let accent = Color(hex: 0xFC6B3F)
    static let accent2 = Color(hex: 0xFFB86B)
    static let live = Color(hex: 0xFF3B3B)
    static let focusRing = Color.white.opacity(0.95)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Type tints

enum ProgramType {
    case drama, sports, news, kids, movie, reality, comedy, doc, game

    static func from(_ program: Program) -> ProgramType {
        let cat = (program.categories.first ?? "").lowercased()
        if cat.contains("sport") { return .sports }
        if cat.contains("news") { return .news }
        if cat.contains("kid") || cat.contains("child") { return .kids }
        if cat.contains("movie") || cat.contains("film") { return .movie }
        if cat.contains("reality") { return .reality }
        if cat.contains("comedy") || cat.contains("sitcom") { return .comedy }
        if cat.contains("documentary") { return .doc }
        if cat.contains("game show") { return .game }
        return .drama
    }

    var gradient: LinearGradient {
        let stops: [Color]
        switch self {
        case .drama:   stops = [Color(hex: 0x1A2342), Color(hex: 0x2C4070)]
        case .sports:  stops = [Color(hex: 0x3D1F0E), Color(hex: 0x7A3A18)]
        case .news:    stops = [Color(hex: 0x1A1F2C), Color(hex: 0x36465E)]
        case .kids:    stops = [Color(hex: 0x2A1F4A), Color(hex: 0x5E3A8A)]
        case .movie:   stops = [Color(hex: 0x2A0E1A), Color(hex: 0x5E1F3A)]
        case .reality: stops = [Color(hex: 0x1F2A1A), Color(hex: 0x3E5A36)]
        case .comedy:  stops = [Color(hex: 0x3A2A0E), Color(hex: 0x7A5A1A)]
        case .doc:     stops = [Color(hex: 0x0E2A2A), Color(hex: 0x1F5A5A)]
        case .game:    stops = [Color(hex: 0x2A1A2A), Color(hex: 0x5A2A5A)]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Focus payload

private struct FocusedItem: Equatable, Hashable {
    let channelID: String
    let programID: String
}

// MARK: - GuideView

struct GuideView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics

    @State private var viewportStart: Date = Self.snapToHalfHour(.now)
    @State private var presentedChannel: Channel?
    @State private var detailProgram: Program?

    // Focus drives the hero card.
    @State private var focusedProgram: Program?
    @State private var focusedChannel: Channel?

    // Animated now-line pulse
    @State private var nowLinePulse: Bool = false

    // Debounced tune-on-focus: a brief dwell on a row retunes the active stream
    // to that row's channel so the hero tile previews it.
    @State private var pendingTune: Task<Void, Never>?

    var body: some View {
        Group {
            if metrics.useTimelineGuide {
                TimelineGuideView(
                    onTune: { ch in
                        appModel.tune(to: ch)
                        presentedChannel = ch
                    },
                    onShowProgramDetail: { detailProgram = $0 }
                )
            } else {
                gridBody
            }
        }
        .task { nowLinePulse = true }
        .onChange(of: focusedChannel?.id) { _, newID in
            scheduleTune(channelID: newID)
        }
        .fullScreenCover(item: $presentedChannel) { channel in
            NowPlayingView(channel: channel)
                .environment(appModel)
        }
        .sheet(item: $detailProgram) { program in
            ProgramDetailView(program: program)
        }
    }

    @ViewBuilder
    private var gridBody: some View {
        ZStack(alignment: .topLeading) {
            backgroundGradient.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                controls
                    .padding(.horizontal, metrics.contentHorizontalPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 18)

                GuideHeroCardView(
                    program: focusedProgram,
                    channel: focusedChannel,
                    showLivePreview: shouldShowLivePreview,
                    onWatchLive: { ch in
                        appModel.tune(to: ch)
                        presentedChannel = ch
                    },
                    onMoreInfo: { detailProgram = $0 }
                )
                .padding(.horizontal, metrics.contentHorizontalPadding)
                .frame(height: metrics.heroHeight)

                Spacer(minLength: 24)

                gridSection
                    .padding(.leading, metrics.contentHorizontalPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Whether the hero art tile should mount a live `VLCPlayerView`. Requires:
    /// (a) fullscreen player isn't presented (avoids two views fighting over the
    /// VLC drawable), and (b) the active player is on the focused row's channel.
    private var shouldShowLivePreview: Bool {
        guard presentedChannel == nil else { return false }
        guard let focused = focusedChannel,
              let active = appModel.player.activeChannel
        else { return false }
        return focused.id == active.id
    }

    private func scheduleTune(channelID: String?) {
        pendingTune?.cancel()
        guard let channelID,
              let target = focusedChannel,
              target.id == channelID
        else { return }
        if appModel.player.activeChannel?.id == channelID { return }
        pendingTune = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            // Re-check: focus may have moved during the wait.
            guard let stillFocused = focusedChannel,
                  stillFocused.id == channelID
            else { return }
            if appModel.player.activeChannel?.id != channelID {
                appModel.tune(to: stillFocused)
            }
        }
    }

    private var backgroundGradient: some View {
        RadialGradient(
            colors: [GuideTokens.bgGrad1, GuideTokens.bgGrad2],
            center: .top,
            startRadius: 200,
            endRadius: 1400
        )
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                viewportStart = viewportStart.addingTimeInterval(-30 * 60)
            } label: {
                Label("Earlier", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)

            Button {
                viewportStart = Self.snapToHalfHour(.now)
            } label: {
                Label("Now", systemImage: "clock")
            }
            .buttonStyle(.glassProminent)

            Button {
                viewportStart = viewportStart.addingTimeInterval(30 * 60)
            } label: {
                Label("Later", systemImage: "chevron.right")
            }
            .buttonStyle(.glass)

            Spacer()

            Text(viewportStart, format: .dateTime.weekday().month().day())
                .font(.headline)
                .foregroundStyle(GuideTokens.text2)
        }
    }

    private var gridSection: some View {
        let totalSlots = GuideTokens.visibleSlots
        let windowEnd = viewportStart.addingTimeInterval(Double(totalSlots) * 30 * 60)

        return VStack(alignment: .leading, spacing: 12) {
            GuideTimeHeader(
                viewportStart: viewportStart,
                slotCount: totalSlots,
                pulse: nowLinePulse
            )

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: GuideTokens.rowGap) {
                        ForEach(appModel.visibleChannels.prefix(64)) { channel in
                            row(for: channel, windowEnd: windowEnd)
                        }
                    }
                    .padding(.bottom, 60)

                    nowLineOverlay
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for channel: Channel, windowEnd: Date) -> some View {
        let view = GuideRowView(
            channel: channel,
            viewportStart: viewportStart,
            windowEnd: windowEnd,
            onTapAiring: { ch in
                appModel.tune(to: ch)
                presentedChannel = ch
            },
            onTapFuture: { detailProgram = $0 },
            onFocus: { program, ch in
                focusedProgram = program
                focusedChannel = ch
            }
        )
        #if os(tvOS)
        view.focusSection()
        #else
        view
        #endif
    }

    /// Vertical red bar at the current time, layered above the rows.
    private var nowLineOverlay: some View {
        let nowOffset = CGFloat(Date.now.timeIntervalSince(viewportStart) / 60) * metrics.pxPerMinute
        let visibleWidth = CGFloat(GuideTokens.visibleSlots) * metrics.guideTimeColumnWidth
        let isInWindow = nowOffset >= 0 && nowOffset <= visibleWidth
        return Group {
            if isInWindow {
                Rectangle()
                    .fill(GuideTokens.live)
                    .frame(width: 2)
                    .shadow(color: GuideTokens.live.opacity(0.6), radius: 6, x: 0, y: 0)
                    .opacity(nowLinePulse ? 1.0 : 0.85)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: nowLinePulse)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(x: metrics.guideChannelRailWidth + nowOffset)
            }
        }
    }

    private static func snapToHalfHour(_ date: Date) -> Date {
        let interval: TimeInterval = 30 * 60
        let snapped = floor(date.timeIntervalSince1970 / interval) * interval
        return Date(timeIntervalSince1970: snapped)
    }
}

// MARK: - Time header

private struct GuideTimeHeader: View {
    let viewportStart: Date
    let slotCount: Int
    let pulse: Bool

    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: metrics.guideChannelRailWidth)
                ForEach(0..<slotCount, id: \.self) { i in
                    let date = viewportStart.addingTimeInterval(Double(i) * 30 * 60)
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(GuideTokens.text3)
                        .monospacedDigit()
                        .frame(width: metrics.guideTimeColumnWidth, alignment: .leading)
                }
            }

            // Floating red "now" pill
            let nowOffset = CGFloat(Date.now.timeIntervalSince(viewportStart) / 60) * metrics.pxPerMinute
            let visibleWidth = CGFloat(slotCount) * metrics.guideTimeColumnWidth
            if nowOffset >= 0 && nowOffset <= visibleWidth {
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 16, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(GuideTokens.live, in: .rect(cornerRadius: 6))
                    .shadow(color: GuideTokens.live.opacity(0.5), radius: 8, x: 0, y: 0)
                    .offset(x: metrics.guideChannelRailWidth + nowOffset - 24, y: -4)
            }
        }
        .frame(height: 32, alignment: .topLeading)
    }
}

// MARK: - Row

private struct GuideRowView: View {
    let channel: Channel
    let viewportStart: Date
    let windowEnd: Date
    let onTapAiring: (Channel) -> Void
    let onTapFuture: (Program) -> Void
    let onFocus: (Program, Channel) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics
    @State private var programs: [Program] = []
    @State private var didLoad: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            GuideChannelRailCell(channel: channel)
                .frame(width: metrics.guideChannelRailWidth, height: metrics.guideRowHeight, alignment: .leading)

            ZStack(alignment: .topLeading) {
                if didLoad && programs.isEmpty {
                    Text("No listings — refresh in Settings")
                        .font(.system(size: 14))
                        .foregroundStyle(GuideTokens.text4)
                        .padding(.horizontal, 16)
                }
                ForEach(programs) { program in
                    GuideProgramCell(
                        program: program,
                        channel: channel,
                        viewportStart: viewportStart,
                        windowEnd: windowEnd,
                        onTap: {
                            if program.start <= .now && program.stop > .now {
                                onTapAiring(channel)
                            } else {
                                onTapFuture(program)
                            }
                        },
                        onFocusAcquired: { onFocus(program, channel) }
                    )
                }
            }
            .frame(
                width: CGFloat(GuideTokens.visibleSlots) * metrics.guideTimeColumnWidth,
                height: metrics.guideRowHeight,
                alignment: .topLeading
            )
            .clipped()
        }
        .task(id: TaskKey(channelID: channel.id, viewportStart: viewportStart)) {
            await loadPrograms()
        }
    }

    private func loadPrograms() async {
        let from = viewportStart.addingTimeInterval(-3600)
        let to = windowEnd.addingTimeInterval(3600)
        do {
            programs = try await appModel.programs(for: channel, from: from, to: to)
        } catch {
            programs = []
        }
        didLoad = true
    }

    private struct TaskKey: Hashable {
        let channelID: String
        let viewportStart: Date
    }
}

// MARK: - Channel rail

private struct GuideChannelRailCell: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 14) {
            GuideChannelLogo(channel: channel, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.guideNumber)
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(GuideTokens.text)
                HStack(spacing: 6) {
                    Text(channel.guideName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GuideTokens.text3)
                        .lineLimit(1)
                    if channel.isHD {
                        Text("· 4K")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(GuideTokens.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 16)
    }
}

private struct GuideChannelLogo: View {
    let channel: Channel
    let size: CGFloat

    var body: some View {
        AsyncImage(url: channel.iconURL) { phase in
            switch phase {
            case .empty: fallback
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            case .failure: fallback
            @unknown default: fallback
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(GuideTokens.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.18)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 2)
    }

    private var fallback: some View {
        Text(initials)
            .font(.system(size: size * 0.30, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var initials: String {
        let name = channel.guideName.uppercased()
        let letters = name.compactMap { $0.isLetter ? $0 : nil }
        return String(letters.prefix(3))
    }
}

// MARK: - Program cell

private struct GuideProgramCell: View {
    let program: Program
    let channel: Channel
    let viewportStart: Date
    let windowEnd: Date
    let onTap: () -> Void
    let onFocusAcquired: () -> Void

    @Environment(\.layoutMetrics) private var metrics

    #if os(tvOS)
    @Environment(\.isFocused) private var environmentFocused
    private var isHighlighted: Bool { environmentFocused }
    #else
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    private var isHighlighted: Bool { isHovered || isPressed }
    #endif

    var body: some View {
        Button(action: onTap) {
            cellBody
        }
        .buttonStyle(.plain)
        .offset(x: offsetX, y: 0)
        .scaleEffect(isHighlighted ? 1.04 : 1.0, anchor: .leading)
        .zIndex(isHighlighted ? 3 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
        .onChange(of: isHighlighted) { _, newValue in
            if newValue { onFocusAcquired() }
        }
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        #endif
    }

    @ViewBuilder
    private var cellBody: some View {
        let tint = ProgramType.from(program)
        let textColor = isHighlighted ? Color.white : GuideTokens.text
        let subTextColor = isHighlighted ? Color.white.opacity(0.78) : GuideTokens.text3

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if program.isLive {
                    Circle()
                        .fill(GuideTokens.live)
                        .frame(width: 8, height: 8)
                }
                Text(program.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                if program.isNew && spanSlots >= 2 {
                    Text("NEW")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isHighlighted
                                ? AnyShapeStyle(Color.black.opacity(0.4))
                                : AnyShapeStyle(GuideTokens.accent.opacity(0.18))
                        )
                        .foregroundStyle(isHighlighted ? Color.white : GuideTokens.accent2)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            if let subtitle = program.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(subTextColor)
                    .lineLimit(1)
            } else {
                Text(program.start, format: .dateTime.hour().minute())
                    .font(.system(size: 14))
                    .foregroundStyle(subTextColor)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: width, height: metrics.guideRowHeight, alignment: .topLeading)
        .background(cellBackground(tint: tint))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isHighlighted ? GuideTokens.focusRing : GuideTokens.border,
                    lineWidth: isHighlighted ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(
            color: isHighlighted ? .black.opacity(0.5) : .clear,
            radius: isHighlighted ? 20 : 0,
            x: 0,
            y: isHighlighted ? 16 : 0
        )
    }

    @ViewBuilder
    private func cellBackground(tint: ProgramType) -> some View {
        if isHighlighted {
            tint.gradient
        } else {
            GuideTokens.surface
        }
    }

    private var clampedStart: Date { max(program.start, viewportStart) }
    private var clampedStop: Date { min(program.stop, windowEnd) }

    private var spanSlots: Int {
        let minutes = clampedStop.timeIntervalSince(clampedStart) / 60
        return max(1, Int(round(minutes / 30)))
    }

    /// Cells fill their time slot minus a 6pt gap so adjacent cells don't touch.
    private var width: CGFloat {
        max(40, CGFloat(clampedStop.timeIntervalSince(clampedStart) / 60) * metrics.pxPerMinute - 6)
    }

    private var offsetX: CGFloat {
        CGFloat(clampedStart.timeIntervalSince(viewportStart) / 60) * metrics.pxPerMinute
    }
}

// MARK: - Hero card

private struct GuideHeroCardView: View {
    let program: Program?
    let channel: Channel?
    let showLivePreview: Bool
    let onWatchLive: (Channel) -> Void
    let onMoreInfo: (Program) -> Void

    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        if let program, let channel {
            HStack(alignment: .bottom, spacing: 36) {
                artTile(for: program, channel: channel)
                detailColumn(program: program, channel: channel)
            }
        } else {
            placeholder
        }
    }

    private func artTile(for program: Program, channel: Channel) -> some View {
        let tint = ProgramType.from(program)
        return ZStack(alignment: .bottomLeading) {
            // Backdrop: type-tinted gradient. Always present; serves as a
            // placeholder while the VLC player buffers in.
            Rectangle().fill(tint.gradient)
            RadialGradient(
                colors: [Color.white.opacity(0.18), Color.clear],
                center: .init(x: 0.3, y: 0.3),
                startRadius: 0,
                endRadius: 240
            )

            // Live layer: VLCPlayerView crossfades in once the active player
            // is on the focused channel. .id() rebuilds the view on channel
            // change rather than mutating in place.
            if showLivePreview {
                VLCPlayerView()
                    .id(channel.id)
                    .transition(.opacity)
                // Bottom legibility scrim so the call sign stays readable
                // over arbitrary video content.
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.6)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }

            HStack {
                Text(program.title.uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(2.0)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                if channel.isHD {
                    UHDBadge()
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: metrics.heroCardSize.width, height: metrics.heroCardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 16)
        .animation(.easeInOut(duration: 0.25), value: showLivePreview)
    }

    private func detailColumn(program: Program, channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                GuideChannelLogo(channel: channel, size: 44)
                Text("\(channel.guideNumber) · \(channel.guideName)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(GuideTokens.text2)
                if program.isNew {
                    Text("NEW")
                        .font(.system(size: 14, weight: .heavy))
                        .tracking(1.0)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(GuideTokens.accent.opacity(0.18), in: .rect(cornerRadius: 4))
                        .foregroundStyle(GuideTokens.accent2)
                }
                if let rating = program.rating, !rating.isEmpty {
                    Text(rating)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(GuideTokens.borderStrong, lineWidth: 1)
                        )
                        .foregroundStyle(GuideTokens.text2)
                }
            }
            Text(program.title)
                .font(.system(size: 56, weight: .bold))
                .tracking(-0.6)
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text)

            HStack(spacing: 8) {
                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(GuideTokens.text2)
                }
                Text(timeRange(for: program))
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(GuideTokens.text3)
            }
            .lineLimit(1)

            if let desc = program.desc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 22))
                    .foregroundStyle(GuideTokens.text2)
                    .lineLimit(2)
                    .frame(maxWidth: 820, alignment: .leading)
            }

            HStack(spacing: 14) {
                Button { onWatchLive(channel) } label: {
                    Label("Watch Live", systemImage: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(GuideHeroPrimaryButtonStyle())
                .disabled(!isAiring(program))

                Button { /* record stub */ } label: {
                    Text("Record Series")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(GuideHeroSecondaryButtonStyle())

                Button { onMoreInfo(program) } label: {
                    Text("More Info")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(GuideHeroSecondaryButtonStyle())
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: some View {
        HStack(alignment: .center, spacing: 24) {
            RoundedRectangle(cornerRadius: 18)
                .fill(GuideTokens.surface)
                .frame(width: metrics.heroCardSize.width, height: metrics.heroCardSize.height)
            VStack(alignment: .leading, spacing: 12) {
                Text("Tonight's Guide")
                    .font(.system(size: 56, weight: .bold))
                    .tracking(-0.6)
                Text("Pick a program for details.")
                    .font(.system(size: 22))
                    .foregroundStyle(GuideTokens.text3)
            }
            Spacer()
        }
    }

    private func timeRange(for program: Program) -> String {
        let f = Date.FormatStyle().hour().minute()
        return "\(program.start.formatted(f)) – \(program.stop.formatted(f))"
    }

    private func isAiring(_ program: Program) -> Bool {
        let now = Date.now
        return program.start <= now && program.stop > now
    }
}

// MARK: - Hero buttons

private struct GuideHeroPrimaryButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var envFocused
    #else
    private let envFocused = false
    #endif
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GuideTokens.bg)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.95), lineWidth: 4)
                    .blur(radius: envFocused ? 0 : 0.001)
                    .opacity(envFocused ? 1 : 0)
            )
            .shadow(color: .black.opacity(0.5), radius: envFocused ? 20 : 8, x: 0, y: envFocused ? 14 : 6)
            .scaleEffect(configuration.isPressed ? 0.98 : (envFocused ? 1.05 : 1.0))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: envFocused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct GuideHeroSecondaryButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var envFocused
    #else
    private let envFocused = false
    #endif
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GuideTokens.text)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(envFocused ? Color.white.opacity(0.18) : GuideTokens.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(envFocused ? GuideTokens.focusRing : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(envFocused ? 0.4 : 0), radius: envFocused ? 16 : 0, x: 0, y: envFocused ? 12 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : (envFocused ? 1.05 : 1.0))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: envFocused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Badges

struct UHDBadge: View {
    var body: some View {
        Text("4K HDR")
            .font(.system(size: 14, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(Color(hex: 0x1A0A04))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                LinearGradient(
                    colors: [GuideTokens.accent, GuideTokens.accent2],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: .rect(cornerRadius: 4)
            )
    }
}
