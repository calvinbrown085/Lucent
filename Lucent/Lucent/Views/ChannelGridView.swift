import SwiftUI
import TVCore

struct ChannelGridView: View {
    @Environment(AppModel.self) private var appModel
    @State private var presentedChannel: Channel?

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 360), spacing: 32)]

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
                        if !appModel.favoriteChannels.isEmpty {
                            section(title: "Favorites", channels: appModel.favoriteChannels)
                        }
                        section(title: "All Channels", channels: appModel.visibleChannels)
                        if appModel.visibleChannels.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
                }
            }
            .navigationTitle("Lucent")
            .fullScreenCover(item: $presentedChannel) { channel in
                NowPlayingView(channel: channel)
                    .environment(appModel)
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
                        presentedChannel = channel
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
            Text("No channels yet")
                .font(.title3)
                .foregroundStyle(GuideTokens.text)
            Text("Open Settings and enter your HDHomeRun's IP address.")
                .foregroundStyle(GuideTokens.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct ChannelCard: View {
    let channel: Channel
    let action: () -> Void
    @Environment(\.isFocused) private var isFocused
    @Environment(AppModel.self) private var appModel
    @State private var nowPlaying: Program?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(channel.guideNumber)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
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
                        isFocused ? GuideTokens.focusRing : GuideTokens.border,
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .shadow(
                color: isFocused ? .black.opacity(0.5) : .clear,
                radius: isFocused ? 24 : 0,
                x: 0,
                y: isFocused ? 16 : 0
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .task(id: channel.id) {
            nowPlaying = try? await appModel.nowPlaying(for: channel)
        }
    }
}
