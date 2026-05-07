import SwiftUI
import TVCore

/// Compact-width fallback for the EPG guide on iPhone-portrait. Shows a
/// horizontally-scrolling channel chip picker on top and a vertical list of
/// programs for the selected channel below. Used in place of the wall-of-grid
/// `GuideView.gridBody` when `metrics.useTimelineGuide` is true.
struct TimelineGuideView: View {
    let onTune: (Channel) -> Void
    let onShowProgramDetail: (Program) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutMetrics) private var metrics
    @State private var selectedChannelID: String?
    @State private var programs: [Program] = []
    @State private var didLoad: Bool = false
    @State private var loadTask: Task<Void, Never>?

    private static let lookbackHours: Double = 1
    private static let lookaheadHours: Double = 6

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                channelStrip
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider().background(GuideTokens.border)

                if let selected = selectedChannel {
                    programList(for: selected)
                } else {
                    emptyState
                }
            }
        }
        .task(id: appModel.visibleChannels.first?.id) {
            if selectedChannelID == nil {
                selectedChannelID = appModel.player.activeChannel?.id
                    ?? appModel.visibleChannels.first?.id
            }
            await loadPrograms()
        }
        .onChange(of: selectedChannelID) { _, _ in
            loadTask?.cancel()
            loadTask = Task { await loadPrograms() }
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

    private var channelStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(appModel.visibleChannels) { channel in
                        ChannelChip(
                            channel: channel,
                            isSelected: channel.id == selectedChannelID
                        ) {
                            selectedChannelID = channel.id
                        }
                        .id(channel.id)
                    }
                }
                .padding(.horizontal, metrics.contentHorizontalPadding)
            }
            .onChange(of: selectedChannelID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func programList(for channel: Channel) -> some View {
        List {
            Section {
                if didLoad && programs.isEmpty {
                    Text("No listings — refresh in Settings")
                        .font(.subheadline)
                        .foregroundStyle(GuideTokens.text4)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(programs) { program in
                        Button {
                            if isAiring(program) {
                                onTune(channel)
                            } else {
                                onShowProgramDetail(program)
                            }
                        } label: {
                            programRow(program: program)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        #if !os(tvOS)
                        .listRowSeparator(.hidden)
                        #endif
                    }
                }
            } header: {
                channelHeader(for: channel)
            }
        }
        .listStyle(.plain)
        #if !os(tvOS)
        .scrollContentBackground(.hidden)
        #endif
    }

    private func channelHeader(for channel: Channel) -> some View {
        HStack(spacing: 12) {
            Text(channel.guideNumber)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(GuideTokens.text)
            Text(channel.guideName)
                .font(.headline)
                .foregroundStyle(GuideTokens.text2)
            Spacer()
            if appModel.player.activeChannel?.id == channel.id {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(GuideTokens.live)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func programRow(program: Program) -> some View {
        let airing = isAiring(program)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.start, format: .dateTime.hour().minute())
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(airing ? GuideTokens.live : GuideTokens.text2)
                Text(program.stop, format: .dateTime.hour().minute())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(GuideTokens.text4)
            }
            .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if airing {
                        Circle()
                            .fill(GuideTokens.live)
                            .frame(width: 7, height: 7)
                    }
                    Text(program.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GuideTokens.text)
                        .lineLimit(2)
                    if program.isNew {
                        Text("NEW")
                            .font(.caption2.weight(.heavy))
                            .tracking(0.6)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(GuideTokens.accent.opacity(0.18), in: .rect(cornerRadius: 3))
                            .foregroundStyle(GuideTokens.accent2)
                    }
                }
                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GuideTokens.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if airing {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(GuideTokens.accent)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 56))
                .foregroundStyle(GuideTokens.text3)
            Text("No channels yet")
                .font(.headline)
                .foregroundStyle(GuideTokens.text)
            Text("Add an HDHomeRun in Settings.")
                .font(.subheadline)
                .foregroundStyle(GuideTokens.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedChannel: Channel? {
        guard let id = selectedChannelID else { return nil }
        return appModel.visibleChannels.first { $0.id == id }
    }

    private func loadPrograms() async {
        guard let channel = selectedChannel else {
            programs = []
            didLoad = true
            return
        }
        didLoad = false
        let from = Date.now.addingTimeInterval(-Self.lookbackHours * 3600)
        let to = Date.now.addingTimeInterval(Self.lookaheadHours * 3600)
        do {
            let result = try await appModel.programs(for: channel, from: from, to: to)
            programs = result
        } catch {
            programs = []
        }
        didLoad = true
    }

    private func isAiring(_ program: Program) -> Bool {
        let now = Date.now
        return program.start <= now && program.stop > now
    }
}

private struct ChannelChip: View {
    let channel: Channel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(channel.guideNumber)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text(channel.guideName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : GuideTokens.text2)
            .background(
                Capsule()
                    .fill(isSelected ? GuideTokens.accent : GuideTokens.surface)
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : GuideTokens.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
