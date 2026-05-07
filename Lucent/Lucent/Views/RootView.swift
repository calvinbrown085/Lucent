import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

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
        .environment(\.layoutMetrics, resolvedMetrics)
    }

    private var resolvedMetrics: LayoutMetrics {
        #if os(tvOS)
        return .tvOS
        #else
        return LayoutMetrics.resolve(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        #endif
    }
}
