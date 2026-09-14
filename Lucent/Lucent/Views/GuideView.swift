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

    /// One perceptual family: every stop pair is oklch(0.32 0.07 H) →
    /// oklch(0.45 0.10 H), hue per genre, pre-converted to sRGB. Keeping
    /// lightness/chroma constant means no genre's focused cell shouts louder
    /// than another; edit hues, not individual hexes.
    var gradient: LinearGradient {
        let stops: [Color]
        switch self {
        case .drama:   stops = [Color(hex: 0x203156), Color(hex: 0x38538D)] // H 264
        case .sports:  stops = [Color(hex: 0x4D2809), Color(hex: 0x7F4413)] // H 55
        case .news:    stops = [Color(hex: 0x013752), Color(hex: 0x005C86)] // H 238
        case .kids:    stops = [Color(hex: 0x3B294F), Color(hex: 0x624581)] // H 305
        case .movie:   stops = [Color(hex: 0x4F222E), Color(hex: 0x823B4E)] // H 5
        case .reality: stops = [Color(hex: 0x133C1F), Color(hex: 0x236436)] // H 150
        case .comedy:  stops = [Color(hex: 0x3E3200), Color(hex: 0x675400)] // H 95
        case .doc:     stops = [Color(hex: 0x003D41), Color(hex: 0x00656B)] // H 200
        case .game:    stops = [Color(hex: 0x462444), Color(hex: 0x743F6F)] // H 330
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Genre filter

enum GuideGenreFilter: String, CaseIterable, Identifiable {
    case all, sports, movies, news, kids, comedy, drama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .sports: return "Sports"
        case .movies: return "Movies"
        case .news: return "News"
        case .kids: return "Kids"
        case .comedy: return "Comedy"
        case .drama: return "Drama"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .sports: return "sportscourt"
        case .movies: return "film"
        case .news: return "newspaper"
        case .kids: return "figure.and.child.holdinghands"
        case .comedy: return "face.smiling"
        case .drama: return "theatermasks"
        }
    }

    func matches(_ program: Program) -> Bool {
        switch self {
        case .all: return true
        case .sports: return ProgramType.from(program) == .sports
        case .movies: return ProgramType.from(program) == .movie
        case .news: return ProgramType.from(program) == .news
        case .kids: return ProgramType.from(program) == .kids
        case .comedy: return ProgramType.from(program) == .comedy
        case .drama: return ProgramType.from(program) == .drama
        }
    }
}

// MARK: - Jump targets

enum GuideJumpTarget: CaseIterable, Identifiable {
    case now, tonight, tomorrow

    var id: Self { self }

    var label: String {
        switch self {
        case .now: return "Now"
        case .tonight: return "Tonight"
        case .tomorrow: return "Tomorrow"
        }
    }

    var symbol: String {
        switch self {
        case .now: return "clock"
        case .tonight: return "moon.stars"
        case .tomorrow: return "sunrise"
        }
    }

    /// Resolve to a viewport start. Tonight = 8 pm today (or now if it's
    /// already past); Tomorrow = 8 am.
    func viewportStart(now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .now:
            return now
        case .tonight:
            let eight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
            return max(eight, now)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }

    /// The days a Day picker should offer: today plus the next six, matching
    /// the week of listings Gracenote ingests. Each lands at 8 am.
    static func dayOptions(now: Date = .now, calendar: Calendar = .current) -> [(label: String, start: Date)] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)
            else { return nil }
            let label: String
            switch offset {
            case 0: label = "Today"
            case 1: label = "Tomorrow"
            default: label = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            return (label: label, start: offset == 0 ? max(start, now) : start)
        }
    }
}

// MARK: - Focus payload

private struct FocusedItem: Equatable, Hashable {
    let channelID: String
    /// `nil` when the row's "no listings" placeholder cell is focused.
    let programID: String?
}

// MARK: - GuideView

struct GuideView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewportStart: Date = Self.snapToHalfHour(.now)
    @State private var presentedChannel: Channel?
    @State private var detailProgram: Program?
    @State private var genre: GuideGenreFilter = .all

    /// Channels with at least one program matching `genre` in the current
    /// window. Filled by the genre query; `nil` while a query is in flight
    /// on first switch so rows don't flash empty.
    @State private var genreChannelIDs: Set<String>?

    // Single source of truth for which cell has focus. Cells bind to it with
    // `.focused(_:equals:)`, the hero derives from it, and tvOS left/right
    // moves it explicitly (see `moveFocusHorizontally`).
    @FocusState private var focusedItem: FocusedItem?

    // Programs each row currently has loaded, keyed by channel ID, so the
    // hero and horizontal navigation can resolve a `FocusedItem` without
    // another store round-trip.
    @State private var rowPrograms: [String: [Program]] = [:]

    // Derived from `focusedItem`; kept as state so the hero holds its last
    // program while focus sits on the hero buttons or the time controls.
    @State private var focusedProgram: Program?
    @State private var focusedChannel: Channel?

    // Animated now-line pulse
    @State private var nowLinePulse: Bool = false

    // Debounced tune-on-focus: a brief dwell on a row retunes the active stream
    // to that row's channel so the hero tile previews it.
    @State private var pendingTune: Task<Void, Never>?

    // Captured at the start of a horizontal drag so each onChanged tick is
    // applied as a delta from the gesture's origin viewport.
    @State private var dragBaselineStart: Date?

    var body: some View {
        Group {
            if metrics.useTimelineGuide {
                TimelineGuideView(
                    onTune: { ch in
                        appModel.tune(to: ch)
                        if !appModel.prefersDockedPlayback { presentedChannel = ch }
                    },
                    onShowProgramDetail: { detailProgram = $0 }
                )
            } else {
                gridBody
            }
        }
        .task { nowLinePulse = true }
        // The guide always opens on "now": state survives tab switches and
        // the app can sit resident for days, so the stored viewport is
        // re-anchored every time the screen appears or the app comes back.
        .onAppear { viewportStart = Self.snapToHalfHour(.now) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewportStart = Self.snapToHalfHour(.now) }
        }
        .onChange(of: focusedItem) { _, item in
            syncHero(to: item)
        }
        .onChange(of: focusedChannel?.id) { _, newID in
            scheduleTune(channelID: newID)
        }
        .fullScreenCover(item: $presentedChannel) { channel in
            NowPlayingView(channel: channel)
                .environment(appModel)
                .environment(\.layoutMetrics, metrics)
        }
        .sheet(item: $detailProgram) { program in
            ProgramDetailView(program: program)
                .environment(appModel)
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
                        if !appModel.prefersDockedPlayback { presentedChannel = ch }
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
        guard presentedChannel == nil, !appModel.dockedPlayerVisible else { return false }
        guard let focused = focusedChannel,
              let active = appModel.player.activeChannel
        else { return false }
        return focused.id == active.id
    }

    /// Resolve a focused cell to the channel + program the hero shows. A
    /// `nil` item (focus moved to the hero buttons or time controls) leaves
    /// the hero on whatever it last showed.
    private func syncHero(to item: FocusedItem?) {
        guard let item,
              let channel = appModel.visibleChannels.first(where: { $0.id == item.channelID })
        else { return }
        focusedChannel = channel
        if let programID = item.programID {
            focusedProgram = rowPrograms[channel.id]?.first { $0.id == programID }
        } else {
            focusedProgram = nil
        }
    }

    #if os(tvOS)
    /// tvOS left/right at the edges of the time window. The focus engine
    /// handles ordinary in-row moves itself — and `onMoveCommand` fires *in
    /// addition* to that move, so anything we do here for a move the engine
    /// could make would double-step. We therefore act only when the engine
    /// has nothing to move to: the focused cell is clipped at that edge, or
    /// the neighbouring program lies outside the window. Then we pan time
    /// and place focus explicitly.
    private func moveFocusHorizontally(_ direction: Int, windowEnd: Date) {
        let slot: TimeInterval = 30 * 60
        let shift = Double(direction) * slot

        guard let item = focusedItem,
              let programID = item.programID,
              let list = rowPrograms[item.channelID],
              let current = list.first(where: { $0.id == programID })
        else {
            // Placeholder cell (or nothing resolvable) — just pan time.
            viewportStart = viewportStart.addingTimeInterval(shift)
            return
        }

        if direction > 0 {
            // Clipped at the right edge: reveal more of the same program.
            if current.stop > windowEnd {
                viewportStart = viewportStart.addingTimeInterval(slot)
                return
            }
            guard let next = list.first(where: { $0.start > current.start }) else {
                viewportStart = viewportStart.addingTimeInterval(slot)
                return
            }
            // Next program is on screen: the engine moves there on its own.
            guard next.start >= windowEnd else { return }
            let lastSlotStart = Self.snapToHalfHour(next.start)
                .addingTimeInterval(-Double(metrics.guideVisibleSlots - 1) * slot)
            viewportStart = max(viewportStart.addingTimeInterval(slot), lastSlotStart)
            focusedItem = FocusedItem(channelID: item.channelID, programID: next.id)
        } else {
            if current.start < viewportStart {
                viewportStart = viewportStart.addingTimeInterval(-slot)
                return
            }
            guard let prev = list.last(where: { $0.start < current.start }) else {
                viewportStart = viewportStart.addingTimeInterval(-slot)
                return
            }
            guard prev.stop <= viewportStart else { return }
            viewportStart = min(
                viewportStart.addingTimeInterval(-slot),
                Self.snapToHalfHour(prev.start)
            )
            focusedItem = FocusedItem(channelID: item.channelID, programID: prev.id)
        }
    }
    #endif

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

    @ViewBuilder
    private var controls: some View {
        if metrics.compactGuide {
            ScrollView(.horizontal, showsIndicators: false) {
                controlsRow
            }
        } else {
            controlsRow
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                viewportStart = viewportStart.addingTimeInterval(-30 * 60)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Earlier")

            ForEach(GuideJumpTarget.allCases) { target in
                Button {
                    viewportStart = Self.snapToHalfHour(target.viewportStart())
                } label: {
                    Label(target.label, systemImage: target.symbol)
                }
                .buttonStyle(.glass)
            }

            Menu {
                ForEach(GuideJumpTarget.dayOptions(), id: \.start) { option in
                    Button(option.label) {
                        viewportStart = Self.snapToHalfHour(option.start)
                    }
                }
            } label: {
                Label("Day", systemImage: "calendar")
            }
            .buttonStyle(.glass)

            Button {
                viewportStart = viewportStart.addingTimeInterval(30 * 60)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Later")

            Divider()
                .frame(height: 28)
                .overlay(GuideTokens.borderStrong)

            Menu {
                ForEach(GuideGenreFilter.allCases) { g in
                    Button {
                        genre = g
                    } label: {
                        Label(g.label, systemImage: g.symbol)
                    }
                }
            } label: {
                Label(genre == .all ? "Genre" : genre.label, systemImage: genre.symbol)
                    .foregroundStyle(genre == .all ? GuideTokens.text : GuideTokens.accent2)
            }
            .buttonStyle(.glass)

            Spacer()

            Text(viewportStart, format: .dateTime.weekday().month().day())
                .font(.headline)
                .foregroundStyle(GuideTokens.text2)
        }
        .task(id: GenreQueryKey(genre: genre, viewportStart: viewportStart, refresh: appModel.lastEPGRefresh)) {
            await refreshGenreFilter()
        }
    }

    private struct GenreQueryKey: Hashable {
        let genre: GuideGenreFilter
        let viewportStart: Date
        let refresh: Date?
    }

    /// Genre filtering is done in one store query over the visible window
    /// rather than per row, so switching genres doesn't fan out 64 reads.
    private func refreshGenreFilter() async {
        guard genre != .all else {
            genreChannelIDs = nil
            return
        }
        let windowEnd = viewportStart.addingTimeInterval(Double(metrics.guideVisibleSlots) * 30 * 60)
        let needle: String
        switch genre {
        case .sports: needle = "sport"
        case .movies: needle = "movie"
        case .news: needle = "news"
        case .kids: needle = "kid"
        case .comedy: needle = "comedy"
        case .drama: needle = "drama"
        case .all: needle = ""
        }
        let matches = (try? await appModel.programs(inCategoryContaining: needle, from: viewportStart, to: windowEnd)) ?? []
        let xmltvIDs = Set(matches.filter { genre.matches($0) }.map(\.channelXmltvID))
        genreChannelIDs = Set(appModel.visibleChannels.filter { xmltvIDs.contains($0.xmltvID) }.map(\.id))
    }

    private var filteredChannels: [Channel] {
        let all = appModel.visibleChannels
        guard genre != .all, let ids = genreChannelIDs else { return all }
        return all.filter { ids.contains($0.id) }
    }

    private var gridSection: some View {
        let totalSlots = metrics.guideVisibleSlots
        let windowEnd = viewportStart.addingTimeInterval(Double(totalSlots) * 30 * 60)

        let section = VStack(alignment: .leading, spacing: 12) {
            GuideTimeHeader(
                viewportStart: viewportStart,
                slotCount: totalSlots,
                pulse: nowLinePulse
            )

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: GuideTokens.rowGap) {
                        ForEach(filteredChannels.prefix(64)) { channel in
                            row(for: channel, windowEnd: windowEnd)
                        }
                        if genre != .all, genreChannelIDs?.isEmpty == true {
                            Text("Nothing in \(genre.label) for this time window.")
                                .font(.system(size: 20 * metrics.typeScale))
                                .foregroundStyle(GuideTokens.text3)
                                .padding(.top, 24)
                        }
                    }
                    .padding(.bottom, 60)

                    nowLineOverlay
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: viewportStart)

        #if os(tvOS)
        return section
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    moveFocusHorizontally(-1, windowEnd: windowEnd)
                case .right:
                    moveFocusHorizontally(1, windowEnd: windowEnd)
                default:
                    break
                }
            }
        #else
        return section
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        let baseline = dragBaselineStart ?? viewportStart
                        if dragBaselineStart == nil { dragBaselineStart = baseline }
                        // Drag left → translation.width negative → reveal later content.
                        let minutes = -value.translation.width / metrics.pxPerMinute
                        viewportStart = baseline.addingTimeInterval(minutes * 60)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            viewportStart = Self.snapToHalfHour(viewportStart)
                        }
                        dragBaselineStart = nil
                    }
            )
        #endif
    }

    @ViewBuilder
    private func row(for channel: Channel, windowEnd: Date) -> some View {
        let view = GuideRowView(
            channel: channel,
            viewportStart: viewportStart,
            windowEnd: windowEnd,
            onTapAiring: { ch in
                appModel.tune(to: ch)
                if !appModel.prefersDockedPlayback { presentedChannel = ch }
            },
            onTapFuture: { detailProgram = $0 },
            genre: genre,
            onProgramsLoaded: { loaded in
                rowPrograms[channel.id] = loaded
                // A row that finished loading while its cell is already
                // focused (e.g. right after a refresh) must still feed the hero.
                if focusedItem?.channelID == channel.id { syncHero(to: focusedItem) }
            },
            focus: $focusedItem
        )
        #if os(tvOS)
        view.focusSection()
        #else
        view
        #endif
    }

    /// Vertical red bar at the current time, layered above the rows.
    /// TimelineView keeps it moving while the guide sits idle — computing from
    /// `Date.now` in a plain body freezes it until something else invalidates
    /// the view.
    private var nowLineOverlay: some View {
        TimelineView(.everyMinute) { context in
            let nowOffset = CGFloat(context.date.timeIntervalSince(viewportStart) / 60) * metrics.pxPerMinute
            let visibleWidth = CGFloat(metrics.guideVisibleSlots) * metrics.guideTimeColumnWidth
            let isInWindow = nowOffset >= 0 && nowOffset <= visibleWidth
            if isInWindow {
                Rectangle()
                    .fill(GuideTokens.live)
                    .frame(width: 2)
                    .shadow(color: GuideTokens.live.opacity(0.6), radius: 6, x: 0, y: 0)
                    // No repeatForever pulse here: a perpetual SwiftUI
                    // animation kept the attribute graph re-evaluating every
                    // frame even underneath the fullscreen player (~5% of
                    // main-thread time in the iPhone trace).
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
                        .font(.system(size: 20 * metrics.typeScale, weight: .semibold))
                        .foregroundStyle(GuideTokens.text3)
                        .monospacedDigit()
                        .frame(width: metrics.guideTimeColumnWidth, alignment: .leading)
                }
            }

            // Floating red "now" pill. TimelineView keeps the clock text and
            // position current while the guide sits idle.
            TimelineView(.everyMinute) { context in
                let nowOffset = CGFloat(context.date.timeIntervalSince(viewportStart) / 60) * metrics.pxPerMinute
                let visibleWidth = CGFloat(slotCount) * metrics.guideTimeColumnWidth
                if nowOffset >= 0 && nowOffset <= visibleWidth {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 16 * metrics.typeScale, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(GuideTokens.live, in: .rect(cornerRadius: 6))
                        .shadow(color: GuideTokens.live.opacity(0.5), radius: 8, x: 0, y: 0)
                        .offset(x: metrics.guideChannelRailWidth + nowOffset - 24, y: -4)
                }
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
    let genre: GuideGenreFilter
    let onProgramsLoaded: ([Program]) -> Void
    let focus: FocusState<FocusedItem?>.Binding

    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics
    @State private var programs: [Program] = []
    @State private var didLoad: Bool = false

    var body: some View {
        let visible = programs.filter { $0.stop > viewportStart && $0.start < windowEnd }

        HStack(spacing: 0) {
            GuideChannelRailCell(channel: channel)
                .frame(width: metrics.guideChannelRailWidth, height: metrics.guideRowHeight, alignment: .leading)

            ZStack(alignment: .topLeading) {
                // Every row must contain a focusable cell, otherwise the tvOS
                // focus engine has nothing to land on and vertical navigation
                // stops dead at the row above. The placeholder also keeps the
                // channel selectable (press = watch it) when the guide has no
                // data for it.
                if visible.isEmpty {
                    GuideEmptyRowCell(
                        message: didLoad && programs.isEmpty
                            ? "No listings — refresh in Settings"
                            : "No listings for this time",
                        channel: channel,
                        onTap: { onTapAiring(channel) },
                        focus: focus
                    )
                }
                ForEach(visible) { program in
                    GuideProgramCell(
                        program: program,
                        channel: channel,
                        viewportStart: viewportStart,
                        windowEnd: windowEnd,
                        dimmed: !genre.matches(program),
                        onTap: {
                            if program.start <= .now && program.stop > .now {
                                onTapAiring(channel)
                            } else {
                                onTapFuture(program)
                            }
                        },
                        focus: focus
                    )
                }
            }
            .frame(
                width: CGFloat(metrics.guideVisibleSlots) * metrics.guideTimeColumnWidth,
                height: metrics.guideRowHeight,
                alignment: .topLeading
            )
            .clipped()
        }
        .task(
            id: TaskKey(
                channelID: channel.id,
                viewportStart: viewportStart,
                epgRefresh: appModel.lastEPGRefresh
            )
        ) {
            await loadPrograms()
        }
    }

    private func loadPrograms() async {
        let from = viewportStart.addingTimeInterval(-3600)
        let to = windowEnd.addingTimeInterval(3600)
        let result: [Program]
        do {
            result = try await appModel.programs(for: channel, from: from, to: to)
        } catch {
            result = []
        }
        // .task(id:) cancelled us if the viewport moved on — the DB read
        // doesn't abort mid-flight, so a stale result can land after the
        // replacement task's. Drop it instead of clobbering newer data.
        guard !Task.isCancelled else { return }
        programs = result
        didLoad = true
        onProgramsLoaded(result)
    }

    private struct TaskKey: Hashable {
        let channelID: String
        let viewportStart: Date
        /// Rows are loaded once per channel+viewport, so without this a row
        /// that rendered before the guide finished refreshing would sit on
        /// "No listings" until the viewport moved. Bumping the key on every
        /// completed refresh reloads exactly once per refresh.
        let epgRefresh: Date?
    }
}

// MARK: - Channel rail

private struct GuideChannelRailCell: View {
    let channel: Channel
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        HStack(spacing: 14 * metrics.typeScale) {
            GuideChannelLogo(channel: channel, size: 56 * metrics.typeScale)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.guideNumber)
                    .font(.system(size: 22 * metrics.typeScale, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(GuideTokens.text)
                // No per-row HD tag: nearly every OTA channel is HD, so it
                // reads as noise repeated down the rail. HD lives in the
                // channel cards and the hero badge instead.
                Text(channel.guideName)
                    .font(.system(size: 16 * metrics.typeScale, weight: .semibold))
                    .foregroundStyle(GuideTokens.text3)
                    .lineLimit(1)
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

// MARK: - Empty row cell

private struct GuideEmptyRowCell: View {
    let message: String
    let channel: Channel
    let onTap: () -> Void
    let focus: FocusState<FocusedItem?>.Binding

    @Environment(\.layoutMetrics) private var metrics

    private var item: FocusedItem { FocusedItem(channelID: channel.id, programID: nil) }

    #if os(tvOS)
    private var isHighlighted: Bool { focus.wrappedValue == item }
    #else
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    private var isHighlighted: Bool { isHovered || isPressed }
    #endif

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "tv")
                    .font(.system(size: 16 * metrics.typeScale, weight: .semibold))
                Text(message)
                    .font(.system(size: 16 * metrics.typeScale, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHighlighted ? GuideTokens.text : GuideTokens.text4)
            .padding(.horizontal, 16)
            .frame(
                width: CGFloat(metrics.guideVisibleSlots) * metrics.guideTimeColumnWidth - 6,
                height: metrics.guideRowHeight,
                alignment: .leading
            )
            .background(isHighlighted ? GuideTokens.surface2 : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isHighlighted ? GuideTokens.focusRing : GuideTokens.border,
                        style: StrokeStyle(lineWidth: isHighlighted ? 2 : 1, dash: isHighlighted ? [] : [6, 6])
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(PressTrackingButtonStyle { isPressed = $0 })
        .onHover { isHovered = $0 }
        #endif
        .focused(focus, equals: item)
        .animation(.easeOut(duration: 0.15), value: isHighlighted)
    }
}

// MARK: - Program cell

private struct GuideProgramCell: View {
    let program: Program
    let channel: Channel
    let viewportStart: Date
    let windowEnd: Date
    var dimmed: Bool = false
    let onTap: () -> Void
    let focus: FocusState<FocusedItem?>.Binding

    @Environment(\.layoutMetrics) private var metrics

    private var item: FocusedItem { FocusedItem(channelID: channel.id, programID: program.id) }

    #if os(tvOS)
    private var isHighlighted: Bool { focus.wrappedValue == item }
    #else
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    private var isHighlighted: Bool { isHovered || isPressed }
    #endif

    var body: some View {
        Button(action: onTap) {
            cellBody
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(PressTrackingButtonStyle { isPressed = $0 })
        #endif
        .focused(focus, equals: item)
        .opacity(dimmed && !isHighlighted ? 0.35 : 1)
        .scaleEffect(isHighlighted ? 1.04 : 1.0, anchor: .leading)
        .zIndex(isHighlighted ? 3 : 1)
        // Leading padding rather than `.offset` so the cell's layout frame —
        // which is what the focus engine measures — is at its real position.
        .padding(.leading, offsetX)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
        #if !os(tvOS)
        .onHover { isHovered = $0 }
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
                    if spanSlots >= 2 {
                        Text("LIVE")
                            .font(.system(size: 11 * metrics.typeScale, weight: .heavy))
                            .tracking(0.8)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(GuideTokens.live)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Circle()
                            .fill(GuideTokens.live)
                            .frame(width: 8, height: 8)
                    }
                }
                Text(program.title)
                    .font(.system(size: 22 * metrics.typeScale, weight: .bold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                if program.isNew && spanSlots >= 2 {
                    Text("NEW")
                        .font(.system(size: 11 * metrics.typeScale, weight: .heavy))
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
            // Airtime is always visible — it's the one datum every EPG glance
            // needs; the subtitle appends rather than replacing it.
            Text(metaLine)
                .font(.system(size: 14 * metrics.typeScale))
                .foregroundStyle(subTextColor)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 16 * metrics.typeScale)
        .padding(.vertical, 10 * metrics.typeScale)
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

    private var metaLine: String {
        let f = Date.FormatStyle().hour(.defaultDigits(amPM: .omitted)).minute()
        let range = "\(program.start.formatted(f)) – \(program.stop.formatted(f))"
        if let subtitle = program.subtitle, !subtitle.isEmpty {
            return "\(range) · \(subtitle)"
        }
        return range
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
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let channel {
            HStack(alignment: .bottom, spacing: 36 * metrics.typeScale) {
                if !metrics.compactGuide {
                    artTile(for: program, channel: channel)
                }
                if let program {
                    detailColumn(program: program, channel: channel)
                } else {
                    channelOnlyColumn(channel: channel)
                }
            }
        } else {
            placeholder
        }
    }

    private func artTile(for program: Program?, channel: Channel) -> some View {
        let tint = program.map(ProgramType.from) ?? .drama
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

            // Live layer: the picture crossfades in once the active player is
            // on the focused channel (`LiveVideoLayer` resolves to VLC, or to
            // the demo ident in demo mode). .id() rebuilds the view on channel
            // change rather than mutating in place.
            if showLivePreview {
                LiveVideoLayer(channel: channel, program: program, compact: true)
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
                Text((program?.title ?? channel.guideName).uppercased())
                    .font(.system(size: 14 * metrics.typeScale, weight: .heavy))
                    .tracking(2.0)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                if channel.isHD {
                    HDBadge()
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
                    .font(.system(size: 22 * metrics.typeScale, weight: .semibold))
                    .foregroundStyle(GuideTokens.text2)
                if program.isNew {
                    Text("NEW")
                        .font(.system(size: 14 * metrics.typeScale, weight: .heavy))
                        .tracking(1.0)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(GuideTokens.accent.opacity(0.18), in: .rect(cornerRadius: 4))
                        .foregroundStyle(GuideTokens.accent2)
                }
                if let rating = program.rating, !rating.isEmpty {
                    Text(rating)
                        .font(.system(size: 18 * metrics.typeScale, weight: .semibold))
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
                .font(.system(size: 56 * metrics.typeScale, weight: .bold))
                .tracking(-0.6)
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text)

            HStack(spacing: 8) {
                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 24 * metrics.typeScale, weight: .regular))
                        .foregroundStyle(GuideTokens.text2)
                }
                if let ep = program.episodeNumber, !ep.isEmpty {
                    Text(ep)
                        .font(.system(size: 20 * metrics.typeScale, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(GuideTokens.text3)
                }
                Text(timeRange(for: program))
                    .font(.system(size: 22 * metrics.typeScale, weight: .regular))
                    .foregroundStyle(GuideTokens.text3)
            }
            .lineLimit(1)

            if let desc = program.desc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 22 * metrics.typeScale))
                    .foregroundStyle(GuideTokens.text2)
                    .lineLimit(2)
                    .frame(maxWidth: 820, alignment: .leading)
            }

            HStack(spacing: 14) {
                Button { onWatchLive(channel) } label: {
                    Label("Watch Live", systemImage: "play.fill")
                        .font(.system(size: 22 * metrics.typeScale, weight: .bold))
                        .padding(.horizontal, 28 * metrics.typeScale)
                        .padding(.vertical, 14 * metrics.typeScale)
                }
                .buttonStyle(GuideHeroPrimaryButtonStyle())
                .disabled(!isAiring(program))

                Button { onMoreInfo(program) } label: {
                    Text("More Info")
                        .font(.system(size: 22 * metrics.typeScale, weight: .semibold))
                        .padding(.horizontal, 28 * metrics.typeScale)
                        .padding(.vertical, 14 * metrics.typeScale)
                }
                .buttonStyle(GuideHeroSecondaryButtonStyle())

                if FeatureFlags.reminders, program.start > .now {
                    let set = appModel.reminders.isSet(programID: program.id)
                    Button { appModel.reminders.toggle(program: program, channel: channel) } label: {
                        Label(set ? "Reminder Set" : "Remind Me", systemImage: set ? "bell.fill" : "bell")
                            .font(.system(size: 22 * metrics.typeScale, weight: .semibold))
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(GuideHeroSecondaryButtonStyle())
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hero for a row with no listings: channel identity, an honest "no
    /// listings" line, and Watch Live (the tuner doesn't need guide data).
    private func channelOnlyColumn(channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                GuideChannelLogo(channel: channel, size: 44)
                Text("\(channel.guideNumber) · \(channel.guideName)")
                    .font(.system(size: 22 * metrics.typeScale, weight: .semibold))
                    .foregroundStyle(GuideTokens.text2)
            }
            Text(channel.guideName)
                .font(.system(size: 56 * metrics.typeScale, weight: .bold))
                .tracking(-0.6)
                .lineLimit(1)
                .foregroundStyle(GuideTokens.text)

            Text("No listings available for this channel.")
                .font(.system(size: 22 * metrics.typeScale))
                .foregroundStyle(GuideTokens.text3)

            HStack(spacing: 14) {
                Button { onWatchLive(channel) } label: {
                    Label("Watch Live", systemImage: "play.fill")
                        .font(.system(size: 22 * metrics.typeScale, weight: .bold))
                        .padding(.horizontal, 28 * metrics.typeScale)
                        .padding(.vertical, 14 * metrics.typeScale)
                }
                .buttonStyle(GuideHeroPrimaryButtonStyle())
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: some View {
        HStack(alignment: .center, spacing: 24) {
            if !metrics.compactGuide {
                RoundedRectangle(cornerRadius: 18)
                    .fill(GuideTokens.surface)
                    .frame(width: metrics.heroCardSize.width, height: metrics.heroCardSize.height)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Tonight's Guide")
                    .font(.system(size: 56 * metrics.typeScale, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(GuideTokens.text)
                Text("Pick a program for details.")
                    .font(.system(size: 22 * metrics.typeScale))
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

struct HDBadge: View {
    @Environment(\.layoutMetrics) private var metrics
    var body: some View {
        Text("HD")
            .font(.system(size: 14 * metrics.typeScale, weight: .heavy))
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


