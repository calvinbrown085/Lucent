import Foundation
import Observation
import TVCore
#if os(iOS)
import UserNotifications
#endif

/// A "remind me" set on an upcoming program. Carries enough channel identity
/// to tune from a notification without the guide being loaded.
struct ProgramReminder: Codable, Identifiable, Hashable, Sendable {
    /// `Program.id` — one reminder per airing.
    let id: String
    let channelID: String
    let channelNumber: String
    let channelName: String
    let title: String
    let start: Date
    let stop: Date
    var fired: Bool = false
}

/// Local program reminders. Two delivery paths, both driven from the same
/// list:
/// - In-app: a timer wakes every 15 s while the app runs and raises
///   `activeAlert` a few minutes before start; `ReminderBanner` renders it
///   with a Watch button. This is the only path on tvOS, which has no
///   user-visible local notifications.
/// - iOS: a `UNCalendarNotificationTrigger` fires at the same lead time when
///   the app is in the background; tapping it deep-links into a tune via
///   `LucentApp`'s notification delegate.
@Observable
@MainActor
final class ReminderService {
    static let leadMinutes = 5

    private(set) var reminders: [ProgramReminder] = []
    /// The reminder currently shown as an in-app banner, if any.
    var activeAlert: ProgramReminder?

    private let defaults: UserDefaults
    private var ticker: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ProgramReminder].self, from: data) {
            reminders = decoded
        }
        purgeExpired()
    }

    private static let key = "programReminders"

    func isSet(programID: String) -> Bool {
        reminders.contains { $0.id == programID }
    }

    func toggle(program: Program, channel: Channel) {
        if isSet(programID: program.id) {
            remove(programID: program.id)
        } else {
            add(program: program, channel: channel)
        }
    }

    func add(program: Program, channel: Channel) {
        guard program.start > .now else { return }
        let reminder = ProgramReminder(
            id: program.id,
            channelID: channel.id,
            channelNumber: channel.guideNumber,
            channelName: channel.guideName,
            title: program.title,
            start: program.start,
            stop: program.stop
        )
        reminders.removeAll { $0.id == reminder.id }
        reminders.append(reminder)
        reminders.sort { $0.start < $1.start }
        persist()
        #if os(iOS)
        scheduleNotification(for: reminder)
        #endif
    }

    func remove(programID: String) {
        reminders.removeAll { $0.id == programID }
        if activeAlert?.id == programID { activeAlert = nil }
        persist()
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [programID])
        #endif
    }

    func dismissAlert() {
        activeAlert = nil
    }

    /// Upcoming reminders, soonest first.
    var upcoming: [ProgramReminder] {
        reminders.filter { $0.stop > .now }.sorted { $0.start < $1.start }
    }

    func start() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func tick() {
        purgeExpired()
        guard activeAlert == nil else { return }
        let threshold = Date.now.addingTimeInterval(Double(Self.leadMinutes) * 60)
        if let idx = reminders.firstIndex(where: { !$0.fired && $0.start <= threshold && $0.stop > .now }) {
            reminders[idx].fired = true
            activeAlert = reminders[idx]
            persist()
        }
    }

    private func purgeExpired() {
        let before = reminders.count
        reminders.removeAll { $0.stop <= .now }
        if reminders.count != before { persist() }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(reminders), forKey: Self.key)
    }

    #if os(iOS)
    nonisolated static let notificationCategory = "programReminder"
    nonisolated static let channelIDKey = "channelID"

    private func scheduleNotification(for reminder: ProgramReminder) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = "Starts in \(Self.leadMinutes) min on \(reminder.channelNumber) \(reminder.channelName)"
            content.sound = .default
            content.categoryIdentifier = Self.notificationCategory
            content.userInfo = [Self.channelIDKey: reminder.channelID]
            let fireDate = reminder.start.addingTimeInterval(-Double(Self.leadMinutes) * 60)
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
            center.add(request)
        }
    }
    #endif
}
