import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView {
            Tab("Channels", systemImage: "tv") {
                ChannelGridView()
            }
            Tab("Guide", systemImage: "calendar.day.timeline.left") {
                GuideView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tint(GuideTokens.accent)
    }
}
