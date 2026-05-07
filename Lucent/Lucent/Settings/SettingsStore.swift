import Foundation
import Observation

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

    var guideSource: GuideSource {
        didSet { defaults.set(guideSource.rawValue, forKey: Keys.guideSource) }
    }

    var hideChannelsWithoutGuide: Bool {
        didSet { defaults.set(hideChannelsWithoutGuide, forKey: Keys.hideChannelsWithoutGuide) }
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
        self.postalCode = defaults.string(forKey: Keys.postalCode) ?? ""
        self.countryCode = defaults.string(forKey: Keys.countryCode) ?? "USA"
        self.lineupIDOverride = defaults.string(forKey: Keys.lineupIDOverride) ?? ""
        if let raw = defaults.string(forKey: Keys.guideSource), let src = GuideSource(rawValue: raw) {
            self.guideSource = src
        } else {
            self.guideSource = .gracenote
        }
        self.hideChannelsWithoutGuide = defaults.bool(forKey: Keys.hideChannelsWithoutGuide)

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
        static let guideSource = "guideSource"
        static let postalCode = "postalCode"
        static let countryCode = "countryCode"
        static let lineupIDOverride = "lineupIDOverride"
        static let hideChannelsWithoutGuide = "hideChannelsWithoutGuide"
    }
}
