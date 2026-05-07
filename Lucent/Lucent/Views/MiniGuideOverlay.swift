import SwiftUI
import TVCore

/// Right-anchored side panel for browsing what's on other channels without
/// leaving the active stream. Sibling SwiftUI layer over `VLCPlayerView` —
/// **never** wraps the player (would black out VLC's CAEAGLLayer/CAMetalLayer).
struct MiniGuideOverlay: View {
    let activeChannelID: String?
    let onTune: (Channel) -> Void
    let onClose: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var nowPlayingByChannelID: [String: Program] = [:]
    @State private var refreshTask: Task<Void, Never>?
    @FocusState private var focusedChannelID: String?

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            panel
                .frame(width: 540)
                .padding(.trailing, 60)
                .padding(.vertical, 60)
        }
        .ignoresSafeArea()
        .task { await refreshNowPlaying() }
        .onAppear {
            startPeriodicRefresh()
            focusedChannelID = activeChannelID ?? appModel.visibleChannels.first?.id
        }
        .onDisappear { refreshTask?.cancel() }
        .onExitCommand { onClose() }
    }

    private var panel: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Divider().background(GuideTokens.borderStrong)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(appModel.visibleChannels) { channel in
                            MiniGuideRow(
                                channel: channel,
                                program: nowPlayingByChannelID[channel.id],
                                isActive: channel.id == activeChannelID
                            ) {
                                onTune(channel)
                            }
                            .id(channel.id)
                            .focused($focusedChannelID, equals: channel.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .background(Color.black.opacity(0.78), in: .rect(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(GuideTokens.borderStrong, lineWidth: 1)
            )
            .onAppear {
                if let active = activeChannelID {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.title3)
                .foregroundStyle(GuideTokens.text2)
            Text("On now")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GuideTokens.text)
            Spacer()
            Text("\(appModel.visibleChannels.count) channels")
                .font(.caption)
                .foregroundStyle(GuideTokens.text3)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func refreshNowPlaying() async {
        let channels = appModel.visibleChannels
        do {
            nowPlayingByChannelID = try await appModel.nowPlayingBatch(for: channels)
        } catch {
            // Swallow — the overlay degrades to channel-only rows.
        }
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await refreshNowPlaying()
            }
        }
    }
}

private struct MiniGuideRow: View {
    let channel: Channel
    let program: Program?
    let isActive: Bool
    let onSelect: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Text(channel.guideNumber)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isFocused ? .white : GuideTokens.text)
                    .frame(width: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(channel.guideName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(isFocused ? .white : GuideTokens.text2)
                        if isActive {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption2)
                                .foregroundStyle(GuideTokens.live)
                        }
                    }
                    if let program {
                        HStack(spacing: 6) {
                            Text(program.title)
                                .lineLimit(1)
                                .foregroundStyle(isFocused ? Color.white.opacity(0.9) : GuideTokens.text3)
                            if let mins = minutesRemaining(for: program), mins > 0 {
                                Text("· \(mins)m left")
                                    .foregroundStyle(GuideTokens.text4)
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption)
                    } else {
                        Text("No listing")
                            .font(.caption)
                            .foregroundStyle(GuideTokens.text4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isActive ? GuideTokens.accent.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private func minutesRemaining(for program: Program) -> Int? {
        let remaining = program.stop.timeIntervalSince(.now)
        guard remaining > 0 else { return nil }
        return Int(remaining / 60)
    }
}
