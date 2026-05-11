import SwiftUI

@main
struct LucentApp: App {
    @State private var appModel = AppModel()

    init() {
        #if os(iOS)
        AudioSessionConfigurator.activate()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task { await appModel.bootstrap() }
        }
    }
}
