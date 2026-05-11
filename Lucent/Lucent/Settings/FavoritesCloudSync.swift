import Foundation

/// Bridges `SettingsStore.favorites` with `NSUbiquitousKeyValueStore` so the
/// favorites set follows the user across devices signed into the same iCloud
/// account. KVS is sufficient here — favorites is a tiny `Set<String>` payload,
/// well under the 1 MB total limit, and we don't need CloudKit's schema layer.
@MainActor
final class FavoritesCloudSync {
    private let settings: SettingsStore
    private let store: NSUbiquitousKeyValueStore
    private var isApplyingRemote = false

    private static let key = "favorites.v1"

    init(settings: SettingsStore, store: NSUbiquitousKeyValueStore = .default) {
        self.settings = settings
        self.store = store
    }

    /// Subscribe to remote changes and perform a one-time union merge between
    /// the local set and whatever iCloud already has. Call once at app launch.
    /// The observer block captures `self` weakly, so no explicit teardown is
    /// needed — `FavoritesCloudSync` lives for the process lifetime.
    func start() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleExternalChange()
            }
        }

        // Kick a pull. KVS responds asynchronously and posts a change
        // notification when it has news.
        store.synchronize()

        let remote = readRemote()
        let local = settings.favorites
        let union = local.union(remote)

        if union != local {
            isApplyingRemote = true
            settings.favorites = union
            isApplyingRemote = false
        }
        if union != remote, !union.isEmpty {
            writeRemote(union)
        }
        print("[Lucent][iCloudSync] start: local=\(local.count) remote=\(remote.count) union=\(union.count)")
    }

    /// Push the current favorites set to iCloud. Call from `AppModel` after a
    /// local toggle.
    func push(_ favorites: Set<String>) {
        guard !isApplyingRemote else { return }
        writeRemote(favorites)
    }

    private func handleExternalChange() {
        let remote = readRemote()
        guard remote != settings.favorites else { return }
        isApplyingRemote = true
        settings.favorites = remote
        isApplyingRemote = false
        print("[Lucent][iCloudSync] external: applied \(remote.count) channels from iCloud")
    }

    private func readRemote() -> Set<String> {
        guard let array = store.array(forKey: Self.key) as? [String] else { return [] }
        return Set(array)
    }

    private func writeRemote(_ favorites: Set<String>) {
        store.set(favorites.sorted(), forKey: Self.key)
        store.synchronize()
    }
}
