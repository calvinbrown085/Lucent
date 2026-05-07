import SwiftUI
import TVCore

/// Full-screen list for hiding/unhiding channels. Always iterates the
/// **full** `appModel.channels` (not `visibleChannels`) so the user can find
/// and unhide rows they previously hid.
struct ManageChannelsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.settings

        Form {
            Section {
                Toggle("Hide channels without guide data", isOn: $settings.hideChannelsWithoutGuide)
                Text("Channels whose listings haven't loaded (or aren't mapped to your guide source) are excluded from the grid and guide. Use Channel mapping in Settings to fix mismatches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if appModel.channels.isEmpty {
                    Text("Channels will appear here after a successful connection.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.channels) { channel in
                        ManageChannelRow(channel: channel)
                    }
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("Hidden channels disappear from the grid, guide, and up/down switching in Now Playing. Mapping overrides still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Manage channels")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Show all") {
                    settings.hiddenChannels = []
                }
                .disabled(settings.hiddenChannels.isEmpty)
            }
        }
    }
}

private struct ManageChannelRow: View {
    let channel: Channel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Toggle(isOn: hiddenBinding) {
            HStack(spacing: 16) {
                Text(channel.guideNumber)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.guideName)
                        .font(.headline)
                    Text(channel.isHD ? "HD" : "SD")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(HideChannelToggleStyle())
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.hiddenChannels.contains(channel.id) },
            set: { newValue in
                if newValue {
                    appModel.settings.hiddenChannels.insert(channel.id)
                } else {
                    appModel.settings.hiddenChannels.remove(channel.id)
                }
            }
        )
    }
}

/// Inverts the toggle's semantics for display — "Hidden" reads more naturally
/// than "Visible" in the channel list. The underlying binding still tracks
/// "is hidden = true".
private struct HideChannelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                Text(configuration.isOn ? "Hidden" : "Visible")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(configuration.isOn ? .secondary : Color.accentColor)
            }
        }
    }
}
