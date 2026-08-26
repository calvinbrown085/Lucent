import Foundation

/// Bridges `SettingsStore.favorites` with `NSUbiquitousKeyValueStore` so the
/// favorites set follows the user across devices signed into the same iCloud
/// account. KVS is sufficient here — the payload is a few KB, well under the
/// 1 MB total limit, and we don't need CloudKit's schema layer.
///
/// Sync model: one `(isFavorite, updatedAt)` record per channel that has ever
/// been toggled, merged per-channel by newest `updatedAt`. Unfavorites are
/// kept as tombstones (`isFavorite = false`) so they propagate — the v1
/// scheme stored a bare set and union-merged it on every launch, which
/// resurrected any channel unfavorited while another device was offline.
@MainActor
final class FavoritesCloudSync {
    private struct Record: Codable, Equatable {
        var isFavorite: Bool
        var updatedAt: Date
    }

    private let settings: SettingsStore
    private let store: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults

    /// channelID → latest known state. Mirrored to `defaults` so this device's
    /// timestamps survive relaunches and can win merges against stale remote
    /// state.
    private var records: [String: Record] = [:]

    /// v1 stored a bare `[String]` of favorites. Read once as a migration seed
    /// when no v2 payload exists yet; also kept up to date on writes so a
    /// device still running the old app doesn't lose its favorites outright.
    private static let legacyKey = "favorites.v1"
    private static let key = "favorites.v2"
    private static let localRecordsKey = "favoritesSyncRecords.v1"
    /// Tombstones older than this are dropped at write time to bound growth.
    /// 90 days comfortably covers a device that's been off all summer.
    private static let tombstoneRetention: TimeInterval = 90 * 24 * 3600

    init(settings: SettingsStore, store: NSUbiquitousKeyValueStore = .default, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.store = store
        self.defaults = defaults
    }

    /// Subscribe to remote changes and reconcile local state with whatever
    /// iCloud already has. Call once at app launch. The observer block
    /// captures `self` weakly, so no explicit teardown is needed —
    /// `FavoritesCloudSync` lives for the process lifetime.
    func start() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileWithRemote(reason: "external")
            }
        }

        // Kick a pull. KVS responds asynchronously and posts a change
        // notification when it has news.
        store.synchronize()

        records = readLocalRecords()
        seedRecordsFromSettingsIfNeeded()
        reconcileWithRemote(reason: "start")
    }

    /// Push the current favorites set to iCloud. Call from `AppModel` after a
    /// local toggle.
    func push(_ favorites: Set<String>) {
        let now = Date.now
        // Stamp every channel whose favoriteness differs from the last known
        // record — that's the local edit(s) since the previous push.
        let knownFavorites = Set(records.filter(\.value.isFavorite).keys)
        for added in favorites.subtracting(knownFavorites) {
            records[added] = Record(isFavorite: true, updatedAt: now)
        }
        for removed in knownFavorites.subtracting(favorites) {
            records[removed] = Record(isFavorite: false, updatedAt: now)
        }
        writeLocalRecords()
        writeRemote()
    }

    // MARK: - Merge

    private func reconcileWithRemote(reason: String) {
        let remote = readRemoteRecords()
        let merged = Self.merge(records, remote)

        let favorites = Set(merged.filter(\.value.isFavorite).keys)
        if favorites != settings.favorites {
            settings.favorites = favorites
        }
        records = merged
        writeLocalRecords()
        // Write back only when we know something the remote doesn't — avoids
        // devices ping-ponging identical payloads at each other.
        if merged != remote {
            writeRemote()
        }
        print("[Lucent][iCloudSync] \(reason): favorites=\(favorites.count) records=\(merged.count) remoteRecords=\(remote.count)")
    }

    /// Per-channel last-writer-wins. Equal timestamps prefer `isFavorite` so
    /// legacy v1 seeds (all stamped `.distantPast`) keep the old union
    /// behavior instead of deciding by dictionary order.
    private static func merge(
        _ a: [String: Record],
        _ b: [String: Record]
    ) -> [String: Record] {
        var out = a
        for (id, remote) in b {
            guard let local = out[id] else {
                out[id] = remote
                continue
            }
            if remote.updatedAt > local.updatedAt {
                out[id] = remote
            } else if remote.updatedAt == local.updatedAt, remote.isFavorite, !local.isFavorite {
                out[id] = remote
            }
        }
        return out
    }

    /// First run (or first run after the v2 upgrade): `settings.favorites` may
    /// hold channels with no record yet. Seed them stamped `.distantPast` so
    /// any explicit action recorded elsewhere wins the merge.
    private func seedRecordsFromSettingsIfNeeded() {
        for id in settings.favorites where records[id] == nil {
            records[id] = Record(isFavorite: true, updatedAt: .distantPast)
        }
    }

    // MARK: - Storage

    private func readLocalRecords() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.localRecordsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private func writeLocalRecords() {
        prune()
        defaults.set(try? JSONEncoder().encode(records), forKey: Self.localRecordsKey)
    }

    private func readRemoteRecords() -> [String: Record] {
        if let data = store.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            return decoded
        }
        // No v2 payload yet — migrate the legacy set, if any, as ancient
        // "is a favorite" knowledge.
        guard let array = store.array(forKey: Self.legacyKey) as? [String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: array.map {
            ($0, Record(isFavorite: true, updatedAt: .distantPast))
        })
    }

    private func writeRemote() {
        prune()
        guard let data = try? JSONEncoder().encode(records) else { return }
        store.set(data, forKey: Self.key)
        // Keep the legacy key readable for devices still on the v1 scheme.
        let favorites = records.filter(\.value.isFavorite).keys.sorted()
        store.set(favorites, forKey: Self.legacyKey)
        store.synchronize()
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.tombstoneRetention)
        records = records.filter { $0.value.isFavorite || $0.value.updatedAt > cutoff }
    }
}
