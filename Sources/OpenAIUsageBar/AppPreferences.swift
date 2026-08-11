import Foundation

struct UserPreferences: Equatable, Sendable {
    static let defaultRefreshInterval: TimeInterval = 10
    static let minimumRefreshInterval: TimeInterval = 5
    static let maximumRefreshInterval: TimeInterval = 3_600

    let refreshInterval: TimeInterval
    let launchAtLogin: Bool

    init(refreshInterval: TimeInterval, launchAtLogin: Bool) {
        self.refreshInterval = Self.normalizedRefreshInterval(refreshInterval)
        self.launchAtLogin = launchAtLogin
    }

    static func normalizedRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultRefreshInterval }
        return min(max(value.rounded(), minimumRefreshInterval), maximumRefreshInterval)
    }
}

final class PreferencesStore: @unchecked Sendable {
    static let currentLaunchRegistrationVersion = 2

    private enum Key {
        static let legacyKeyName = "apiKeyName"
        static let refreshInterval = "refreshInterval"
        static let launchAtLogin = "launchAtLogin"
        static let launchRegistrationVersion = "launchRegistrationVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UserPreferences {
        defaults.removeObject(forKey: Key.legacyKeyName)
        let refreshInterval = defaults.object(forKey: Key.refreshInterval) == nil
            ? UserPreferences.defaultRefreshInterval
            : defaults.double(forKey: Key.refreshInterval)
        let launchAtLogin = defaults.object(forKey: Key.launchAtLogin) == nil
            ? true
            : defaults.bool(forKey: Key.launchAtLogin)

        return UserPreferences(
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin
        )
    }

    func save(_ preferences: UserPreferences) {
        defaults.removeObject(forKey: Key.legacyKeyName)
        defaults.set(preferences.refreshInterval, forKey: Key.refreshInterval)
        defaults.set(preferences.launchAtLogin, forKey: Key.launchAtLogin)
    }

    var launchRegistrationNeedsRefresh: Bool {
        defaults.integer(forKey: Key.launchRegistrationVersion) < Self.currentLaunchRegistrationVersion
    }

    func markLaunchRegistrationCurrent() {
        defaults.set(Self.currentLaunchRegistrationVersion, forKey: Key.launchRegistrationVersion)
    }
}
