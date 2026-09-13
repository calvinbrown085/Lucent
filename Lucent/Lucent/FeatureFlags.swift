import Foundation

/// Compile-time switches for features that are built but not shipping.
/// Flip to `true` to bring one back; nothing else needs to change.
enum FeatureFlags {
    /// Program reminders: Remind Me buttons, the in-app banner, iOS local
    /// notifications and the Settings list. Parked 2026-09-13.
    static let reminders = false
}
