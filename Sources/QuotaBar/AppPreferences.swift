import Foundation

struct UserPreferences: Equatable, Sendable {
    static let refreshIntervalOptions: [TimeInterval] = [5, 10, 30, 60]
    static let defaultRefreshInterval: TimeInterval = 60
    static let minimumRefreshInterval: TimeInterval = 5
    static let maximumRefreshInterval: TimeInterval = 60

    let refreshInterval: TimeInterval
    let launchAtLogin: Bool
    let showAPIKeyDetails: Bool
    let showMetricCards: Bool
    let showUsageHistory: Bool
    let showDailyUsage: Bool
    let automaticallyUpdates: Bool

    init(
        refreshInterval: TimeInterval,
        launchAtLogin: Bool,
        showAPIKeyDetails: Bool = true,
        showMetricCards: Bool = true,
        showUsageHistory: Bool = true,
        showDailyUsage: Bool = true,
        automaticallyUpdates: Bool = true
    ) {
        self.refreshInterval = Self.normalizedRefreshInterval(refreshInterval)
        self.launchAtLogin = launchAtLogin
        self.showAPIKeyDetails = showAPIKeyDetails
        self.showMetricCards = showMetricCards
        self.showUsageHistory = showUsageHistory
        self.showDailyUsage = showDailyUsage
        self.automaticallyUpdates = automaticallyUpdates
    }

    static func normalizedRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultRefreshInterval }
        return refreshIntervalOptions.min {
            let leftDistance = abs($0 - value)
            let rightDistance = abs($1 - value)
            return leftDistance == rightDistance ? $0 > $1 : leftDistance < rightDistance
        } ?? defaultRefreshInterval
    }
}

final class PreferencesStore: @unchecked Sendable {
    static let currentLaunchRegistrationVersion = 3

    private enum Key {
        static let legacyKeyName = "apiKeyName"
        static let refreshInterval = "refreshInterval"
        static let launchAtLogin = "launchAtLogin"
        static let showAPIKeyDetails = "showAPIKeyDetails"
        static let showMetricCards = "showMetricCards"
        static let showUsageHistory = "showUsageHistory"
        static let showDailyUsage = "showDailyUsage"
        static let automaticallyUpdates = "automaticallyUpdates"
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
        let showAPIKeyDetails = defaults.object(forKey: Key.showAPIKeyDetails) == nil
            ? true
            : defaults.bool(forKey: Key.showAPIKeyDetails)
        let showMetricCards = defaults.object(forKey: Key.showMetricCards) == nil
            ? true
            : defaults.bool(forKey: Key.showMetricCards)
        let showUsageHistory = defaults.object(forKey: Key.showUsageHistory) == nil
            ? true
            : defaults.bool(forKey: Key.showUsageHistory)
        let showDailyUsage = defaults.object(forKey: Key.showDailyUsage) == nil
            ? true
            : defaults.bool(forKey: Key.showDailyUsage)
        let automaticallyUpdates = defaults.object(forKey: Key.automaticallyUpdates) == nil
            ? true
            : defaults.bool(forKey: Key.automaticallyUpdates)

        return UserPreferences(
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin,
            showAPIKeyDetails: showAPIKeyDetails,
            showMetricCards: showMetricCards,
            showUsageHistory: showUsageHistory,
            showDailyUsage: showDailyUsage,
            automaticallyUpdates: automaticallyUpdates
        )
    }

    func save(_ preferences: UserPreferences) {
        defaults.removeObject(forKey: Key.legacyKeyName)
        defaults.set(preferences.refreshInterval, forKey: Key.refreshInterval)
        defaults.set(preferences.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(preferences.showAPIKeyDetails, forKey: Key.showAPIKeyDetails)
        defaults.set(preferences.showMetricCards, forKey: Key.showMetricCards)
        defaults.set(preferences.showUsageHistory, forKey: Key.showUsageHistory)
        defaults.set(preferences.showDailyUsage, forKey: Key.showDailyUsage)
        defaults.set(preferences.automaticallyUpdates, forKey: Key.automaticallyUpdates)
    }

    var launchRegistrationNeedsRefresh: Bool {
        defaults.integer(forKey: Key.launchRegistrationVersion) < Self.currentLaunchRegistrationVersion
    }

    func markLaunchRegistrationCurrent() {
        defaults.set(Self.currentLaunchRegistrationVersion, forKey: Key.launchRegistrationVersion)
    }
}

enum AppDataMigration {
    static let legacyBundleID = "dev.ruobin.OpenAIUsageBar"
    private static let migrationKey = "didMigrateFromOpenAIUsageBar.v1"
    private static let migratedKeys = [
        "stationProfiles.v1",
        "refreshInterval",
        "launchAtLogin",
        "showAPIKeyDetails",
        "showMetricCards",
        "showUsageHistory",
        "showDailyUsage",
        "automaticallyUpdates",
        "launchRegistrationVersion"
    ]

    static func migrateLegacyDefaultsIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomainName: String = legacyBundleID
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        if let legacy = defaults.persistentDomain(forName: legacyDomainName) {
            for key in migratedKeys where defaults.object(forKey: key) == nil {
                defaults.set(legacy[key], forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}
