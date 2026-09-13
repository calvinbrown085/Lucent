import SwiftUI
#if os(iOS)
import UserNotifications
#endif

@main
struct LucentApp: App {
    @State private var appModel = AppModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

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
                #if os(iOS)
                .onAppear {
                    appDelegate.appModel = appModel
                    appDelegate.flushPendingTune()
                }
                #endif
        }
    }
}

#if os(iOS)
/// Routes a tapped reminder notification into a tune. Kept as a UIKit app
/// delegate because `UNUserNotificationCenterDelegate` must be installed
/// before the app finishes launching for cold-start taps to be delivered.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var appModel: AppModel?
    private var pendingChannelID: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if FeatureFlags.reminders {
            UNUserNotificationCenter.current().delegate = self
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The in-app banner already covers the foreground case.
        []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let channelID = userInfo[ReminderService.channelIDKey] as? String else { return }
        await MainActor.run {
            if let model = appModel {
                model.watch(channelID: channelID)
            } else {
                pendingChannelID = channelID
            }
        }
    }

    /// Deliver a cold-launch tap once the model exists and channels load.
    func flushPendingTune() {
        guard let id = pendingChannelID, let model = appModel else { return }
        pendingChannelID = nil
        model.watch(channelID: id)
    }
}
#endif
