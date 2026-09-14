import Foundation
import Observation

/// Which VLC deinterlacer runs on interlaced (1080i / 480i) broadcasts.
/// Measured on iPhone 16 Pro Max, 1080i, process CPU as % of one core:
/// x 64 · linear 66 (double-rate, 60 fps) · discard 54 · off 50 · blend 42.
/// Software MPEG-2 decode sets the ~50% floor; blend is at it.
enum DeinterlaceMode: String, CaseIterable, Identifiable, Sendable {
    case off, fast, quality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .fast: return "Fast"
        case .quality: return "Quality"
        }
    }

    /// libVLC filter name; nil disables deinterlacing.
    var vlcFilterName: String? {
        switch self {
        case .off: return nil
        case .fast: return "blend"
        case .quality: return "x"
        }
    }

    static var platformDefault: DeinterlaceMode {
        #if os(tvOS)
        return .quality
        #else
        return .fast
        #endif
    }
}

enum GuideSource: String, CaseIterable, Identifiable, Sendable {
    case gracenote
    case xmltvURL

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gracenote: return "Auto (postal code)"
        case .xmltvURL: return "Custom XMLTV URL"
        }
    }
}

@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    var hdhrIP: String {
        didSet { defaults.set(hdhrIP, forKey: Keys.hdhrIP) }
    }

    var xmltvURLString: String {
        didSet { defaults.set(xmltvURLString, forKey: Keys.xmltvURL) }
    }

    var xmltvOverrides: [String: String] {
        didSet { defaults.set(try? JSONEncoder().encode(xmltvOverrides), forKey: Keys.xmltvOverrides) }
    }

    var favorites: Set<String> {
        didSet { defaults.set(try? JSONEncoder().encode(favorites), forKey: Keys.favorites) }
    }

    var hiddenChannels: Set<String> {
        didSet { defaults.set(try? JSONEncoder().encode(hiddenChannels), forKey: Keys.hiddenChannels) }
    }

    var prewarmCount: Int {
        didSet { defaults.set(prewarmCount, forKey: Keys.prewarmCount) }
    }

    /// A/V sync trim in milliseconds. Positive delays audio (for "voices ahead
    /// of lips"), negative advances it. Applied live via AudioLatencyMonitor.
    var audioSyncOffsetMillis: Int {
        didSet { defaults.set(audioSyncOffsetMillis, forKey: Keys.audioSyncOffsetMillis) }
    }

    var guideSource: GuideSource {
        didSet { defaults.set(guideSource.rawValue, forKey: Keys.guideSource) }
    }

    var hideChannelsWithoutGuide: Bool {
        didSet { defaults.set(hideChannelsWithoutGuide, forKey: Keys.hideChannelsWithoutGuide) }
    }

    /// True while generated demo listings are sitting in the EPG cache. Survives
    /// relaunch so `AppModel` can purge them on the first non-demo bootstrap
    /// instead of scanning the whole program table on every launch.
    var demoListingsPresent: Bool {
        didSet { defaults.set(demoListingsPresent, forKey: Keys.demoListingsPresent) }
    }

    /// Most-recently-watched channel IDs, newest first. Drives the "previous
    /// channel" toggle and the Recent strip in the mini-guide.
    var recentChannelIDs: [String] {
        didSet { defaults.set(recentChannelIDs, forKey: Keys.recentChannelIDs) }
    }

    /// Captions preference persisted across launches.
    var captionsEnabled: Bool {
        didSet { defaults.set(captionsEnabled, forKey: Keys.captionsEnabled) }
    }

    /// iPad: keep the live picture docked beside the guide instead of going
    /// fullscreen on every tune.
    var dockedPlayerEnabled: Bool {
        didSet { defaults.set(dockedPlayerEnabled, forKey: Keys.dockedPlayerEnabled) }
    }

    /// iOS / iPadOS: route video through the sample-buffer path so system
    /// Picture in Picture works. Off falls back to VLC's GPU drawable.
    var pipEnabled: Bool {
        didSet { defaults.set(pipEnabled, forKey: Keys.pipEnabled) }
    }

    /// iPhone: use the per-channel timeline list instead of the grid guide.
    var preferTimelineGuide: Bool {
        didSet { defaults.set(preferTimelineGuide, forKey: Keys.preferTimelineGuide) }
    }

    var deinterlaceMode: DeinterlaceMode {
        didSet { defaults.set(deinterlaceMode.rawValue, forKey: Keys.deinterlaceMode) }
    }

    var postalCode: String {
        didSet { defaults.set(postalCode, forKey: Keys.postalCode) }
    }

    var countryCode: String {
        didSet { defaults.set(countryCode, forKey: Keys.countryCode) }
    }

    var lineupIDOverride: String {
        didSet { defaults.set(lineupIDOverride, forKey: Keys.lineupIDOverride) }
    }

    var xmltvURL: URL? {
        let trimmed = xmltvURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hdhrIP = defaults.string(forKey: Keys.hdhrIP) ?? ""
        self.xmltvURLString = defaults.string(forKey: Keys.xmltvURL) ?? ""
        self.prewarmCount = defaults.object(forKey: Keys.prewarmCount) as? Int ?? 1
        self.audioSyncOffsetMillis = defaults.object(forKey: Keys.audioSyncOffsetMillis) as? Int ?? 0
        self.postalCode = defaults.string(forKey: Keys.postalCode) ?? ""
        self.countryCode = defaults.string(forKey: Keys.countryCode) ?? "USA"
        self.lineupIDOverride = defaults.string(forKey: Keys.lineupIDOverride) ?? ""
        if let raw = defaults.string(forKey: Keys.guideSource), let src = GuideSource(rawValue: raw) {
            self.guideSource = src
        } else {
            self.guideSource = .gracenote
        }
        self.hideChannelsWithoutGuide = defaults.bool(forKey: Keys.hideChannelsWithoutGuide)
        self.demoListingsPresent = defaults.bool(forKey: Keys.demoListingsPresent)
        self.recentChannelIDs = defaults.stringArray(forKey: Keys.recentChannelIDs) ?? []
        self.captionsEnabled = defaults.bool(forKey: Keys.captionsEnabled)
        self.dockedPlayerEnabled = defaults.object(forKey: Keys.dockedPlayerEnabled) as? Bool ?? true
        self.pipEnabled = defaults.object(forKey: Keys.pipEnabled) as? Bool ?? true
        if let raw = defaults.string(forKey: Keys.deinterlaceMode), let mode = DeinterlaceMode(rawValue: raw) {
            self.deinterlaceMode = mode
        } else {
            self.deinterlaceMode = .platformDefault
        }
        self.preferTimelineGuide = defaults.bool(forKey: Keys.preferTimelineGuide)

        if let data = defaults.data(forKey: Keys.xmltvOverrides),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.xmltvOverrides = decoded
        } else {
            self.xmltvOverrides = [:]
        }

        if let data = defaults.data(forKey: Keys.favorites),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.favorites = decoded
        } else {
            self.favorites = []
        }

        if let data = defaults.data(forKey: Keys.hiddenChannels),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.hiddenChannels = decoded
        } else {
            self.hiddenChannels = []
        }
    }

    /// Push a channel to the front of the recents list (max 8, unique).
    func recordRecent(_ channelID: String) {
        var list = recentChannelIDs.filter { $0 != channelID }
        list.insert(channelID, at: 0)
        if list.count > 8 { list.removeLast(list.count - 8) }
        recentChannelIDs = list
    }

    func toggleFavorite(_ channelID: String) {
        if favorites.contains(channelID) {
            favorites.remove(channelID)
        } else {
            favorites.insert(channelID)
        }
    }

    func toggleHidden(_ channelID: String) {
        if hiddenChannels.contains(channelID) {
            hiddenChannels.remove(channelID)
        } else {
            hiddenChannels.insert(channelID)
        }
    }

    func isHidden(_ channelID: String) -> Bool {
        hiddenChannels.contains(channelID)
    }

    func setOverride(channelID: String, xmltvID: String?) {
        let trimmed = xmltvID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            xmltvOverrides[channelID] = trimmed
        } else {
            xmltvOverrides.removeValue(forKey: channelID)
        }
    }

    private enum Keys {
        static let hdhrIP = "hdhrIP"
        static let xmltvURL = "xmltvURL"
        static let xmltvOverrides = "xmltvOverrides"
        static let favorites = "favorites"
        static let hiddenChannels = "hiddenChannels"
        static let prewarmCount = "prewarmCount"
        static let audioSyncOffsetMillis = "audioSyncOffsetMillis"
        static let guideSource = "guideSource"
        static let postalCode = "postalCode"
        static let countryCode = "countryCode"
        static let lineupIDOverride = "lineupIDOverride"
        static let hideChannelsWithoutGuide = "hideChannelsWithoutGuide"
        static let demoListingsPresent = "demoListingsPresent"
        static let recentChannelIDs = "recentChannelIDs"
        static let captionsEnabled = "captionsEnabled"
        static let dockedPlayerEnabled = "dockedPlayerEnabled"
        static let pipEnabled = "pipEnabled"
        static let deinterlaceMode = "deinterlaceMode"
        static let preferTimelineGuide = "preferTimelineGuide"
    }
}
