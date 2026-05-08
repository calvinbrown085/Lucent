import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        #if os(tvOS)
        tabs
            .tint(GuideTokens.accent)
            .environment(\.layoutMetrics, resolvedMetrics)
        #else
        GeometryReader { geo in
            tabs
                .tint(GuideTokens.accent)
                .environment(
                    \.layoutMetrics,
                    resolvedMetrics.adapted(toContainerWidth: geo.size.width)
                )
        }
        #endif
    }

    private var tabs: some View {
        TabView {
            Tab("Guide", systemImage: "calendar.day.timeline.left") {
                GuideView()
            }
            Tab("Channels", systemImage: "tv") {
                ChannelGridView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
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
