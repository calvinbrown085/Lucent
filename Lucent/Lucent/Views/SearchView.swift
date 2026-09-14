import SwiftUI
import TVCore

/// Full-text search across the cached guide. Results are grouped by day and
/// resolve back to a channel so a live result can be tuned directly.
struct SearchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics

    @State private var query = ""
    @State private var results: [Program] = []
    @State private var isSearching = false
    @State private var presentedChannel: Channel?
    @State private var detailProgram: Program?
    @State private var searchTask: Task<Void, Never>?

    private var grouped: [(day: Date, programs: [Program])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: results) { cal.startOfDay(for: $0.start) }
        return dict.keys.sorted().map { (day: $0, programs: dict[$0]!.sorted { $0.start < $1.start }) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RadialGradient(
                    colors: [GuideTokens.bgGrad1, GuideTokens.bgGrad2],
                    center: .top, startRadius: 200, endRadius: 1400
                )
                .ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            hint
                        } else if results.isEmpty && !isSearching {
                            Text("No programs match “\(query)”.")
                                .font(.title3)
                                .foregroundStyle(GuideTokens.text3)
                                .padding(.top, 40)
                        }
                        ForEach(grouped, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(group.day, format: .dateTime.weekday(.wide).month().day())
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(GuideTokens.text3)
                                ForEach(group.programs) { program in
                                    SearchResultRow(
                                        program: program,
                                        channel: appModel.channel(forXmltvID: program.channelXmltvID)
                                    ) {
                                        open(program)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, metrics.contentHorizontalPadding)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Titles, episodes, descriptions")
            .onChange(of: query) { _, _ in scheduleSearch() }
            .onChange(of: appModel.lastEPGRefresh) { _, _ in scheduleSearch() }
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
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Search the whole week of listings.", systemImage: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(GuideTokens.text2)
            Text("Try a show, a team, a film title or a word from the description.")
                .font(.body)
                .foregroundStyle(GuideTokens.text3)
        }
        .padding(.top, 20)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            results = (try? await appModel.search(q)) ?? []
        }
    }

    private func open(_ program: Program) {
        let now = Date.now
        if program.start <= now, program.stop > now,
           let channel = appModel.channel(forXmltvID: program.channelXmltvID) {
            appModel.tune(to: channel)
            if !appModel.prefersDockedPlayback { presentedChannel = channel }
        } else {
            detailProgram = program
        }
    }
}

private struct SearchResultRow: View {
    let program: Program
    let channel: Channel?
    let action: () -> Void

    #if os(tvOS)
    @Environment(\.isFocused) private var focused
    #else
    private let focused = false
    #endif

    private var isAiring: Bool {
        let now = Date.now
        return program.start <= now && program.stop > now
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.start, format: .dateTime.hour().minute())
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(GuideTokens.text)
                    Text(channel.map { "\($0.guideNumber) \($0.guideName)" } ?? program.channelXmltvID)
                        .font(.caption)
                        .foregroundStyle(GuideTokens.text3)
                        .lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isAiring {
                            Text("ON NOW")
                                .font(.caption2.weight(.heavy))
                                .tracking(0.8)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(GuideTokens.live, in: .capsule)
                                .foregroundStyle(.white)
                        }
                        Text(program.title)
                            .font(.headline)
                            .foregroundStyle(GuideTokens.text)
                            .lineLimit(1)
                        if program.isNew {
                            Text("NEW")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(GuideTokens.accent2)
                        }
                    }
                    if let sub = program.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundStyle(GuideTokens.text2)
                            .lineLimit(1)
                    }
                    if let desc = program.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(GuideTokens.text3)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isAiring ? "play.fill" : "info.circle")
                    .foregroundStyle(GuideTokens.text3)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? GuideTokens.surface2 : GuideTokens.surface, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(focused ? GuideTokens.focusRing : GuideTokens.border, lineWidth: focused ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focused)
    }
}
