import Foundation

@MainActor
final class UsageStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var phase: UsagePhase = .loading
    private(set) var isRefreshing = false
    private(set) var profiles: [StationProfile] = []
    private(set) var activeProfileID: UUID?
    var onChange: (() -> Void)?

    private let client: any UsageFetching
    private let credentialStore: CredentialStore
    private let profileStore: StationProfileStore
    private let preferencesStore: PreferencesStore
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let weeklyResetMonitor: WeeklyResetMonitor
    private(set) var preferences: UserPreferences
    private(set) var settingsMessage: String?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?

    init(
        client: any UsageFetching = APIClient(),
        credentialStore: CredentialStore = CredentialStore(),
        profileStore: StationProfileStore = StationProfileStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginManager(),
        weeklyResetMonitor: WeeklyResetMonitor = WeeklyResetMonitor(),
        startsPolling: Bool = true
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.profileStore = profileStore
        self.preferencesStore = preferencesStore
        self.launchAtLoginManager = launchAtLoginManager
        self.weeklyResetMonitor = weeklyResetMonitor
        preferences = preferencesStore.load()
        loadProfilesAndMigrate()
        applyLaunchAtLoginPreference()
        if startsPolling { startPolling() }
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
    }

    var activeProfile: StationProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    var needsConfiguration: Bool {
        !configurationProgress.isComplete
    }

    var configurationProgress: ConfigurationProgress {
        guard let profile = activeProfile else {
            return ConfigurationProgress(stationIsValid: false, accountIsValid: false)
        }
        let storedCredentials = credentials(for: profile.id)
        let hasUsableCredentials = storedCredentials.map {
            !$0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.password.isEmpty
        } ?? false
        return ConfigurationProgress(
            stationIsValid: profile.lastCheckedAt != nil,
            accountIsValid: profile.lastAuthenticatedAt != nil && hasUsableCredentials
        )
    }

    var launchAtLoginStatus: String { launchAtLoginManager.statusDescription }

    func credentials(for profileID: UUID) -> Credentials? {
        try? credentialStore.load(for: profileID)
    }

    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult {
        try validate(credentials)
        var validatedProfile = try profile.validated()
        let result = try await client.testConnection(profile: validatedProfile, credentials: credentials)
        try Task.checkCancellation()
        if case .manual(let id) = validatedProfile.subscriptionSelection,
           !result.subscriptions.contains(where: { $0.id == id && $0.status == "active" }) {
            throw APIClientError.missingSubscription
        }
        validatedProfile.capabilities = result.capabilities
        validatedProfile.lastCheckedAt = result.checkedAt
        validatedProfile.lastAuthenticatedAt = result.checkedAt
        try saveProfile(validatedProfile, credentials: credentials)
        await client.invalidateSession()
        snapshot = nil
        phase = .loading
        onChange?()
        refreshNow()
        return result
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {
        try validate(credentials)
        var validatedProfile = try profile.validated()
        if let previous = profiles.first(where: { $0.id == validatedProfile.id }),
           stationEndpointChanged(from: previous, to: validatedProfile) {
            validatedProfile.lastCheckedAt = nil
        }
        try await client.testLogin(profile: validatedProfile, credentials: credentials)
        try Task.checkCancellation()
        validatedProfile.lastAuthenticatedAt = Date()
        try saveProfile(validatedProfile, credentials: credentials)
        await client.invalidateSession()
        snapshot = nil
        phase = .loading
        onChange?()
        refreshNow()
    }

    func updatePreferences(_ updatedPreferences: UserPreferences) throws {
        let launchChanged = updatedPreferences.launchAtLogin != preferences.launchAtLogin
        let intervalChanged = updatedPreferences.refreshInterval != preferences.refreshInterval
        let automaticUpdateChanged = updatedPreferences.automaticallyUpdates != preferences.automaticallyUpdates

        if launchChanged {
            do {
                try launchAtLoginManager.setEnabled(updatedPreferences.launchAtLogin, refreshRegistration: false)
                preferencesStore.markLaunchRegistrationCurrent()
                settingsMessage = launchAtLoginManager.statusDescription
            } catch {
                settingsMessage = "开机启动设置失败：\(error.localizedDescription)"
                onChange?()
                throw error
            }
        }
        preferencesStore.save(updatedPreferences)
        preferences = updatedPreferences
        if automaticUpdateChanged {
            NotificationCenter.default.post(name: .quotaBarUpdatePreferencesChanged, object: nil)
        }
        if intervalChanged { startPolling() }
        onChange?()
    }

    func updateProfile(
        _ profile: StationProfile,
        credentials: Credentials,
        makeActive: Bool = true
    ) async throws {
        try validate(credentials)
        var validatedProfile = try profile.validated()
        if let previous = profiles.first(where: { $0.id == validatedProfile.id }) {
            let endpointChanged = stationEndpointChanged(from: previous, to: validatedProfile)
            if endpointChanged {
                validatedProfile.lastCheckedAt = nil
                validatedProfile.lastAuthenticatedAt = nil
            } else if self.credentials(for: previous.id) != credentials {
                validatedProfile.lastAuthenticatedAt = nil
            }
        }
        try saveProfile(validatedProfile, credentials: credentials, makeActive: makeActive)
        await client.invalidateSession()
        snapshot = nil
        phase = .loading
        onChange?()
        refreshNow()
    }

    func updateStationProfile(_ profile: StationProfile, makeActive: Bool = true) async throws {
        var validatedProfile = try profile.validated()
        var endpointChanged = false
        if let previous = profiles.first(where: { $0.id == validatedProfile.id }) {
            endpointChanged = stationEndpointChanged(from: previous, to: validatedProfile)
            if endpointChanged {
                validatedProfile.lastCheckedAt = nil
                validatedProfile.lastAuthenticatedAt = nil
            }
        }
        do {
            try await client.testStation(profile: validatedProfile)
            validatedProfile.lastCheckedAt = Date()
        } catch {
            try Task.checkCancellation()
            let issue = DashboardIssue.classify(error)
            if issue.kind == .station { validatedProfile.lastCheckedAt = nil }
            if endpointChanged {
                validatedProfile.lastCheckedAt = nil
                validatedProfile.lastAuthenticatedAt = nil
            }
            upsertProfile(validatedProfile, makeActive: makeActive)
            try persistProfiles()
            phase = .failed(issue)
            if issue.settingsTab != nil { snapshot = nil }
            onChange?()
            throw error
        }
        try Task.checkCancellation()
        upsertProfile(validatedProfile, makeActive: makeActive)
        try persistProfiles()
        try Task.checkCancellation()
        guard activeProfileID == validatedProfile.id else { return }
        await client.invalidateSession()
        try Task.checkCancellation()
        snapshot = nil
        phase = validatedProfile.lastAuthenticatedAt == nil ? .needsConfiguration : .loading
        onChange?()
        if credentials(for: validatedProfile.id) != nil { refreshNow() }
    }

    func updateCredentials(_ credentials: Credentials, for profileID: UUID) async throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw StationProfileError.noActiveStation
        }
        let changed = self.credentials(for: profileID) != credentials
        let hasEmail = !credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !credentials.password.isEmpty
        if hasEmail || hasPassword {
            try credentialStore.save(credentials, for: profileID)
        } else {
            try credentialStore.delete(for: profileID)
        }
        if changed { profiles[index].lastAuthenticatedAt = nil }
        try persistProfiles()
        try Task.checkCancellation()
        guard activeProfileID == profileID else { return }
        await client.invalidateSession()
        try Task.checkCancellation()
        snapshot = nil
        phase = hasEmail && hasPassword ? .loading : .needsConfiguration
        onChange?()
        if hasEmail && hasPassword {
            refreshNow()
        }
    }

    func saveConfiguration(
        profile: StationProfile,
        credentials: Credentials,
        refreshInterval: TimeInterval,
        launchAtLogin: Bool,
        showAPIKeyDetails: Bool,
        showMetricCards: Bool,
        showUsageHistory: Bool,
        showDailyUsage: Bool = true,
        automaticallyUpdates: Bool,
        makeActive: Bool = true
    ) async throws {
        settingsMessage = nil
        try validate(credentials)
        var validatedProfile = try profile.validated()
        let testResult = try await client.testConnection(profile: validatedProfile, credentials: credentials)
        validatedProfile.capabilities = testResult.capabilities
        validatedProfile.lastCheckedAt = testResult.checkedAt
        validatedProfile.lastAuthenticatedAt = testResult.checkedAt
        if case .manual(let id) = validatedProfile.subscriptionSelection,
           !testResult.subscriptions.contains(where: { $0.id == id && $0.status == "active" }) {
            throw APIClientError.missingSubscription
        }

        let updatedPreferences = UserPreferences(
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin,
            showAPIKeyDetails: showAPIKeyDetails,
            showMetricCards: showMetricCards,
            showUsageHistory: showUsageHistory,
            showDailyUsage: showDailyUsage,
            automaticallyUpdates: automaticallyUpdates
        )
        try credentialStore.save(credentials, for: validatedProfile.id)
        if let index = profiles.firstIndex(where: { $0.id == validatedProfile.id }) {
            profiles[index] = validatedProfile
        } else {
            profiles.append(validatedProfile)
        }
        if makeActive || activeProfileID == nil { activeProfileID = validatedProfile.id }
        try persistProfiles()
        preferencesStore.save(updatedPreferences)
        preferences = updatedPreferences
        settingsMessage = nil

        do {
            try launchAtLoginManager.setEnabled(launchAtLogin, refreshRegistration: false)
            preferencesStore.markLaunchRegistrationCurrent()
            settingsMessage = launchAtLoginManager.statusDescription
        } catch {
            settingsMessage = "开机启动设置失败：\(error.localizedDescription)"
            onChange?()
            throw error
        }

        await client.invalidateSession()
        snapshot = nil
        phase = .loading
        startPolling()
        onChange?()
        await refresh()
    }

    func selectProfile(_ id: UUID) async throws {
        guard profiles.contains(where: { $0.id == id }) else { throw StationProfileError.noActiveStation }
        guard (try credentialStore.load(for: id)) != nil else { throw StationProfileError.missingCredentials }
        activeProfileID = id
        try persistProfiles()
        await client.invalidateSession()
        snapshot = nil
        phase = .loading
        onChange?()
        await refresh()
    }

    func deleteProfile(_ id: UUID) async throws {
        settingsMessage = nil
        guard profiles.count > 1 else { throw StationProfileError.cannotDeleteOnlyStation }
        try credentialStore.delete(for: id)
        weeklyResetMonitor.removeObservation(for: id)
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = profiles.first?.id }
        try persistProfiles()
        await client.invalidateSession()
        snapshot = nil
        phase = needsConfiguration ? .needsConfiguration : .loading
        onChange?()
        if !needsConfiguration { await refresh() }
    }

    func refresh() async {
        let refreshID = UUID()
        activeRefreshID = refreshID
        guard let profile = activeProfile,
              let credentials = (try? credentialStore.load(for: profile.id)) ?? nil else {
            if let profile = activeProfile,
               let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index].lastAuthenticatedAt = nil
                try? persistProfiles()
            }
            guard activeRefreshID == refreshID else { return }
            activeRefreshID = nil
            isRefreshing = false
            phase = .needsConfiguration
            onChange?()
            return
        }

        isRefreshing = true
        onChange?()
        defer {
            if activeRefreshID == refreshID {
                activeRefreshID = nil
                isRefreshing = false
                onChange?()
            }
        }
        do {
            var usage = try await client.fetchUsage(profile: profile, credentials: credentials)
            guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
            if let weeklyUsage = usage.weeklyUsage {
                let keyIDs = weeklyResetMonitor.resetPlan(
                    profileID: profile.id,
                    subscriptionID: weeklyUsage.subscriptionID,
                    resetAt: weeklyUsage.resetAt,
                    enabled: profile.automaticallyResetsAPIKeyQuota,
                    visibleKeyIDs: usage.keys.filter(\.isVisible).map(\.id)
                )
                var resetSucceeded = false
                var resetFailed = false
                for keyID in keyIDs {
                    guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                    do {
                        try await client.resetAPIKeyQuota(
                            profile: profile,
                            credentials: credentials,
                            keyID: keyID
                        )
                        guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                        weeklyResetMonitor.markKeyHandled(profileID: profile.id, keyID: keyID)
                        resetSucceeded = true
                    } catch {
                        resetFailed = true
                        NSLog("QuotaBar API key %d quota reset failed: %@", keyID, error.localizedDescription)
                    }
                }
                if resetSucceeded {
                    guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                    usage = try await client.fetchUsage(profile: profile, credentials: credentials)
                    guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                }
                guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                if resetFailed {
                    settingsMessage = "API Key 用量自动重置失败，将在下次刷新时重试"
                } else if !keyIDs.isEmpty {
                    settingsMessage = nil
                }
            }
            guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
            snapshot = UsageSnapshot(
                weeklyUsage: usage.weeklyUsage,
                dailyUsage: usage.dailyUsage,
                accountMetrics: usage.accountMetrics,
                keys: usage.keys,
                usageRecords: usage.usageRecords
            )
            markProfileValidated(usage.capabilities, for: profile.id)
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
            let issue = DashboardIssue.classify(error)
            invalidateValidation(for: profile.id, issue: issue)
            if issue.settingsTab != nil { snapshot = nil }
            phase = .failed(issue)
        }
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    private func isCurrentRefresh(_ refreshID: UUID, profileID: UUID) -> Bool {
        activeRefreshID == refreshID && activeProfileID == profileID
    }

    private func loadProfilesAndMigrate() {
        let state = profileStore.load()
        if !state.profiles.isEmpty {
            profiles = state.profiles
            activeProfileID = state.activeProfileID ?? state.profiles.first?.id
            var migratedValidationState = false
            for index in profiles.indices where profiles[index].validationStateVersion == 0 {
                if profiles[index].lastCheckedAt != nil,
                   (try? credentialStore.load(for: profiles[index].id)) != nil {
                    profiles[index].lastAuthenticatedAt = profiles[index].lastCheckedAt
                }
                profiles[index].validationStateVersion = 1
                migratedValidationState = true
            }
            if migratedValidationState { try? persistProfiles() }
        } else {
            let profile = StationProfile.legacyDefault()
            profiles = [profile]
            activeProfileID = profile.id
            do {
                if let legacy = try credentialStore.loadLegacy() {
                    try credentialStore.save(legacy, for: profile.id)
                    try persistProfiles()
                    try credentialStore.deleteLegacy()
                } else {
                    try persistProfiles()
                }
            } catch {
                settingsMessage = "旧配置迁移失败：\(error.localizedDescription)"
            }
        }
        phase = needsConfiguration ? .needsConfiguration : .loading
    }

    private func persistProfiles() throws {
        try profileStore.save(StationProfilesState(profiles: profiles, activeProfileID: activeProfileID))
    }

    private func saveProfile(
        _ profile: StationProfile,
        credentials: Credentials,
        makeActive: Bool = true
    ) throws {
        try credentialStore.save(credentials, for: profile.id)
        upsertProfile(profile, makeActive: makeActive)
        try persistProfiles()
    }

    private func upsertProfile(_ profile: StationProfile, makeActive: Bool) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if makeActive || activeProfileID == nil { activeProfileID = profile.id }
    }

    private func stationEndpointChanged(from previous: StationProfile, to current: StationProfile) -> Bool {
        previous.serviceURL != current.serviceURL
            || previous.apiPath != current.apiPath
            || previous.timezone != current.timezone
    }

    private func markProfileValidated(_ capabilities: Set<StationCapability>, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].capabilities = capabilities
        let now = Date()
        profiles[index].lastCheckedAt = now
        profiles[index].lastAuthenticatedAt = now
        try? persistProfiles()
    }

    private func invalidateValidation(for id: UUID, issue: DashboardIssue) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        switch issue.kind {
        case .authentication:
            profiles[index].lastAuthenticatedAt = nil
        case .station:
            profiles[index].lastCheckedAt = nil
        case .temporary, .unknown:
            return
        }
        try? persistProfiles()
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.preferences.refreshInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func applyLaunchAtLoginPreference() {
        do {
            let needsRefresh = preferencesStore.launchRegistrationNeedsRefresh
            try launchAtLoginManager.setEnabled(preferences.launchAtLogin, refreshRegistration: needsRefresh)
            if preferences.launchAtLogin { preferencesStore.markLaunchRegistrationCurrent() }
            settingsMessage = launchAtLoginManager.statusDescription
        } catch {
            settingsMessage = "开机启动设置失败：\(error.localizedDescription)"
        }
    }

    private func validate(_ credentials: Credentials) throws {
        if credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PreferencesError.emptyEmail
        }
        if credentials.password.isEmpty { throw PreferencesError.emptyPassword }
    }

}

enum PreferencesError: LocalizedError {
    case emptyEmail
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .emptyEmail: return "登录账号不能为空"
        case .emptyPassword: return "登录密码不能为空"
        }
    }
}
