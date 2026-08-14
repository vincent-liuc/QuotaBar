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
    private var refreshTaskID: UUID?
    private var activeRefreshID: UUID?
    private var profileSelectionID = UUID()
    private var endpointTransitionIDs: [UUID: UUID] = [:]
    private var subscriptionOptionsByProfileID: [UUID: [SubscriptionOption]] = [:]

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

    func subscriptionOptions(for profileID: UUID) -> [SubscriptionOption]? {
        subscriptionOptionsByProfileID[profileID]
    }

    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult {
        try validate(credentials)
        var validatedProfile = try profile.validated()
        let startingSelectionID = profileSelectionID
        var transitionID = beginEndpointTransition(to: validatedProfile)
        defer { endEndpointTransition(transitionID, profileID: validatedProfile.id) }
        let result = try await client.testConnection(profile: validatedProfile, credentials: credentials)
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        try requireSelectionAllowsMutation(
            startingSelectionID: startingSelectionID,
            profileID: validatedProfile.id,
            makeActive: true
        )
        if case .manual(let id) = validatedProfile.subscriptionSelection,
           !result.subscriptions.contains(where: { $0.id == id && $0.status == "active" }) {
            throw APIClientError.missingSubscription
        }
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        validatedProfile.capabilities = result.capabilities
        validatedProfile.lastCheckedAt = result.checkedAt
        validatedProfile.lastAuthenticatedAt = result.checkedAt
        try saveProfile(validatedProfile, credentials: credentials)
        let selectionID = profileSelectionID
        subscriptionOptionsByProfileID[validatedProfile.id] = result.subscriptions
        await client.invalidateSession()
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        guard profileSelectionID == selectionID, activeProfileID == validatedProfile.id else { return result }
        snapshot = nil
        phase = .loading
        onChange?()
        endEndpointTransition(transitionID, profileID: validatedProfile.id)
        transitionID = nil
        refreshNow()
        return result
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws -> AccountDiscoveryResult {
        try validate(credentials)
        var validatedProfile = try profile.validated()
        let startingSelectionID = profileSelectionID
        if let previous = profiles.first(where: { $0.id == validatedProfile.id }),
           stationEndpointChanged(from: previous, to: validatedProfile) {
            validatedProfile.lastCheckedAt = nil
            validatedProfile.lastAuthenticatedAt = nil
            validatedProfile.capabilities = []
        } else if let previous = profiles.first(where: { $0.id == validatedProfile.id }) {
            validatedProfile.lastCheckedAt = previous.lastCheckedAt
            validatedProfile.lastAuthenticatedAt = previous.lastAuthenticatedAt
            validatedProfile.capabilities = previous.capabilities
        }
        var transitionID = beginEndpointTransition(to: validatedProfile)
        defer { endEndpointTransition(transitionID, profileID: validatedProfile.id) }
        let result = try await client.discoverAccount(profile: validatedProfile, credentials: credentials)
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        try requireSelectionAllowsMutation(
            startingSelectionID: startingSelectionID,
            profileID: validatedProfile.id,
            makeActive: true
        )
        validatedProfile.lastAuthenticatedAt = Date()
        let discoveredOptions: [SubscriptionOption]?
        switch result.subscriptions {
        case .available(let options):
            validatedProfile.capabilities.insert(.subscriptions)
            discoveredOptions = options
        case .unsupported:
            validatedProfile.capabilities.remove(.subscriptions)
            discoveredOptions = []
        case .failed:
            discoveredOptions = nil
        }
        try saveProfile(validatedProfile, credentials: credentials)
        let selectionID = profileSelectionID
        if let discoveredOptions {
            subscriptionOptionsByProfileID[validatedProfile.id] = discoveredOptions
        }
        await client.invalidateSession()
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        guard profileSelectionID == selectionID, activeProfileID == validatedProfile.id else { return result }
        snapshot = nil
        phase = .loading
        onChange?()
        endEndpointTransition(transitionID, profileID: validatedProfile.id)
        transitionID = nil
        refreshNow()
        return result
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
        var credentialsChanged = false
        if let previous = profiles.first(where: { $0.id == validatedProfile.id }) {
            let endpointChanged = stationEndpointChanged(from: previous, to: validatedProfile)
            credentialsChanged = self.credentials(for: previous.id) != credentials
            if endpointChanged {
                validatedProfile.lastCheckedAt = nil
                validatedProfile.lastAuthenticatedAt = nil
                validatedProfile.capabilities = []
            } else if credentialsChanged {
                validatedProfile.lastCheckedAt = previous.lastCheckedAt
                validatedProfile.lastAuthenticatedAt = nil
                validatedProfile.capabilities = previous.capabilities
            } else {
                validatedProfile.lastCheckedAt = previous.lastCheckedAt
                validatedProfile.lastAuthenticatedAt = previous.lastAuthenticatedAt
                validatedProfile.capabilities = previous.capabilities
            }
        }
        if credentialsChanged && activeProfileID == validatedProfile.id {
            supersedeActiveRefresh()
        }
        try saveProfile(validatedProfile, credentials: credentials, makeActive: makeActive)
        let selectionID = profileSelectionID
        await client.invalidateSession()
        try Task.checkCancellation()
        guard profileSelectionID == selectionID, activeProfileID == validatedProfile.id else { return }
        snapshot = nil
        phase = .loading
        onChange?()
        refreshNow()
    }

    func updateStationProfile(_ profile: StationProfile, makeActive: Bool = true) async throws {
        var validatedProfile = try profile.validated()
        let startingSelectionID = profileSelectionID
        var endpointChanged = false
        let storedProfile = profiles.first(where: { $0.id == validatedProfile.id })
        if let previous = storedProfile {
            endpointChanged = stationEndpointChanged(from: previous, to: validatedProfile)
            if endpointChanged {
                validatedProfile.lastCheckedAt = nil
                validatedProfile.lastAuthenticatedAt = nil
                validatedProfile.capabilities = []
            } else {
                validatedProfile.lastCheckedAt = previous.lastCheckedAt
                validatedProfile.lastAuthenticatedAt = previous.lastAuthenticatedAt
                validatedProfile.capabilities = previous.capabilities
            }
        }
        var transitionID = beginEndpointTransition(to: validatedProfile)
        defer { endEndpointTransition(transitionID, profileID: validatedProfile.id) }
        do {
            try await client.testStation(profile: validatedProfile)
            try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
            try requireSelectionAllowsMutation(
                startingSelectionID: startingSelectionID,
                profileID: validatedProfile.id,
                makeActive: makeActive
            )
            validatedProfile.lastCheckedAt = Date()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
            try requireSelectionAllowsMutation(
                startingSelectionID: startingSelectionID,
                profileID: validatedProfile.id,
                makeActive: makeActive
            )
            let issue = DashboardIssue.classify(error)
            if issue.kind == .station { validatedProfile.lastCheckedAt = nil }
            if endpointChanged {
                validatedProfile.lastCheckedAt = nil
                validatedProfile.lastAuthenticatedAt = nil
            }
            if storedProfile != nil && !endpointChanged {
                upsertProfile(validatedProfile, makeActive: makeActive)
                try persistProfiles()
            }
            if activeProfileID == validatedProfile.id {
                phase = .failed(issue)
                if issue.settingsTab != nil { snapshot = nil }
                onChange?()
            }
            throw error
        }
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        upsertProfile(validatedProfile, makeActive: makeActive)
        try persistProfiles()
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        guard activeProfileID == validatedProfile.id else { return }
        let selectionID = profileSelectionID
        await client.invalidateSession()
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        guard profileSelectionID == selectionID, activeProfileID == validatedProfile.id else { return }
        snapshot = nil
        phase = validatedProfile.lastAuthenticatedAt == nil ? .needsConfiguration : .loading
        onChange?()
        endEndpointTransition(transitionID, profileID: validatedProfile.id)
        transitionID = nil
        if hasUsableCredentials(for: validatedProfile.id) { refreshNow() }
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
        if changed && activeProfileID == profileID { supersedeActiveRefresh() }
        try persistProfiles()
        let selectionID = profileSelectionID
        try Task.checkCancellation()
        guard activeProfileID == profileID else { return }
        await client.invalidateSession()
        try Task.checkCancellation()
        guard profileSelectionID == selectionID, activeProfileID == profileID else { return }
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
        automaticallyUpdates: Bool,
        makeActive: Bool = true
    ) async throws {
        settingsMessage = nil
        try validate(credentials)
        var validatedProfile = try profile.validated()
        let startingSelectionID = profileSelectionID
        var transitionID = beginEndpointTransition(to: validatedProfile)
        defer { endEndpointTransition(transitionID, profileID: validatedProfile.id) }
        let testResult = try await client.testConnection(profile: validatedProfile, credentials: credentials)
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        try requireSelectionAllowsMutation(
            startingSelectionID: startingSelectionID,
            profileID: validatedProfile.id,
            makeActive: makeActive
        )
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
            automaticallyUpdates: automaticallyUpdates
        )
        try saveProfile(validatedProfile, credentials: credentials, makeActive: makeActive)
        let selectionID = profileSelectionID
        subscriptionOptionsByProfileID[validatedProfile.id] = testResult.subscriptions
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
        try requireCurrentEndpointTransition(transitionID, profileID: validatedProfile.id)
        guard profileSelectionID == selectionID, activeProfileID == validatedProfile.id else {
            endEndpointTransition(transitionID, profileID: validatedProfile.id)
            transitionID = nil
            startPolling()
            onChange?()
            return
        }
        snapshot = nil
        phase = .loading
        endEndpointTransition(transitionID, profileID: validatedProfile.id)
        transitionID = nil
        pollingTask?.cancel()
        pollingTask = nil
        onChange?()
        await refresh()
        startPolling(refreshImmediately: false)
    }

    func selectProfile(_ id: UUID) async throws {
        guard profiles.contains(where: { $0.id == id }) else { throw StationProfileError.noActiveStation }
        let previousActiveProfileID = activeProfileID
        if let previousActiveProfileID, previousActiveProfileID != id {
            endpointTransitionIDs.removeValue(forKey: previousActiveProfileID)
        }
        supersedeActiveRefresh()
        let selectionID = UUID()
        profileSelectionID = selectionID
        activeProfileID = id
        try persistProfiles()
        await client.invalidateSession()
        guard profileSelectionID == selectionID, activeProfileID == id else { return }
        snapshot = nil
        guard hasUsableCredentials(for: id) else {
            phase = .needsConfiguration
            onChange?()
            return
        }
        phase = .loading
        onChange?()
        await refresh()
    }

    func deleteProfile(_ id: UUID) async throws {
        settingsMessage = nil
        guard profiles.count > 1 else { throw StationProfileError.cannotDeleteOnlyStation }
        if activeProfileID == id { supersedeActiveRefresh() }
        try credentialStore.delete(for: id)
        weeklyResetMonitor.removeObservation(for: id)
        endpointTransitionIDs.removeValue(forKey: id)
        subscriptionOptionsByProfileID.removeValue(forKey: id)
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            profileSelectionID = UUID()
            activeProfileID = profiles.first?.id
        }
        let selectionID = profileSelectionID
        try persistProfiles()
        await client.invalidateSession()
        guard profileSelectionID == selectionID else { return }
        snapshot = nil
        phase = needsConfiguration ? .needsConfiguration : .loading
        onChange?()
        if !needsConfiguration { await refresh() }
    }

    func refresh() async {
        let task = startRefreshTask()
        await task.value
    }

    private func performRefresh(_ refreshID: UUID) async {
        guard activeRefreshID == refreshID, !Task.isCancelled else { return }
        defer {
            if activeRefreshID == refreshID {
                activeRefreshID = nil
                isRefreshing = false
                onChange?()
            }
        }
        guard let profile = activeProfile else {
            phase = .needsConfiguration
            onChange?()
            return
        }
        guard endpointTransitionIDs[profile.id] == nil else { return }
        guard let credentials = (try? credentialStore.load(for: profile.id)) ?? nil,
              credentialsAreUsable(credentials) else {
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
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
        do {
            var usage = try await client.fetchUsage(profile: profile, credentials: credentials)
            guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
            if let weeklyUsage = usage.weeklyUsage {
                let resetClaim = weeklyResetMonitor.resetClaim(
                    profileID: profile.id,
                    subscriptionID: weeklyUsage.subscriptionID,
                    resetAt: weeklyUsage.resetAt,
                    enabled: profile.automaticallyResetsAPIKeyQuota,
                    visibleKeyIDs: usage.keys.filter(\.isVisible).map(\.id)
                )
                let keyIDs = resetClaim.keyIDs
                var resetSucceeded = false
                var resetFailed = false
                var claimedKeyIDs = Set(keyIDs)
                defer {
                    weeklyResetMonitor.releaseKeyClaims(
                        profileID: profile.id,
                        keyIDs: claimedKeyIDs,
                        claimToken: resetClaim.token
                    )
                }
                for keyID in keyIDs {
                    guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                    do {
                        try Task.checkCancellation()
                        try await client.resetAPIKeyQuota(
                            profile: profile,
                            credentials: credentials,
                            keyID: keyID
                        )
                        let handled = weeklyResetMonitor.markKeyHandled(
                            profileID: profile.id,
                            keyID: keyID,
                            claimToken: resetClaim.token
                        )
                        claimedKeyIDs.remove(keyID)
                        resetSucceeded = resetSucceeded || handled
                        try Task.checkCancellation()
                        guard isCurrentRefresh(refreshID, profileID: profile.id) else { return }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        weeklyResetMonitor.releaseKeyClaims(
                            profileID: profile.id,
                            keyIDs: [keyID],
                            claimToken: resetClaim.token
                        )
                        claimedKeyIDs.remove(keyID)
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
            if let subscriptionOptions = usage.subscriptionOptions {
                subscriptionOptionsByProfileID[profile.id] = subscriptionOptions
            }
            snapshot = UsageSnapshot(
                weeklyUsage: usage.weeklyUsage,
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
        _ = startRefreshTask()
    }

    @discardableResult
    private func startRefreshTask() -> Task<Void, Never> {
        refreshTask?.cancel()
        let taskID = UUID()
        activeRefreshID = taskID
        refreshTaskID = taskID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(taskID)
            if self.refreshTaskID == taskID {
                self.refreshTask = nil
                self.refreshTaskID = nil
            }
        }
        refreshTask = task
        return task
    }

    private func isCurrentRefresh(_ refreshID: UUID, profileID: UUID) -> Bool {
        activeRefreshID == refreshID
            && activeProfileID == profileID
            && endpointTransitionIDs[profileID] == nil
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
            if stationEndpointChanged(from: profiles[index], to: profile) {
                weeklyResetMonitor.removeObservation(for: profile.id)
                subscriptionOptionsByProfileID.removeValue(forKey: profile.id)
                if activeProfileID == profile.id {
                    supersedeActiveRefresh()
                }
            }
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if makeActive || activeProfileID == nil {
            profileSelectionID = UUID()
            activeProfileID = profile.id
        }
    }

    private func stationEndpointChanged(from previous: StationProfile, to current: StationProfile) -> Bool {
        previous.serviceURL != current.serviceURL
            || previous.apiPath != current.apiPath
            || previous.timezone != current.timezone
    }

    private func beginEndpointTransition(to candidate: StationProfile) -> UUID? {
        let transitionID = UUID()
        endpointTransitionIDs[candidate.id] = transitionID
        if activeProfileID == candidate.id {
            supersedeActiveRefresh()
        }
        return transitionID
    }

    private func requireCurrentEndpointTransition(_ transitionID: UUID?, profileID: UUID) throws {
        try Task.checkCancellation()
        guard let transitionID else { return }
        guard endpointTransitionIDs[profileID] == transitionID else { throw CancellationError() }
    }

    private func requireSelectionAllowsMutation(
        startingSelectionID: UUID,
        profileID: UUID,
        makeActive: Bool
    ) throws {
        try Task.checkCancellation()
        guard !makeActive
                || profileSelectionID == startingSelectionID
                || activeProfileID == profileID else {
            throw CancellationError()
        }
    }

    private func endEndpointTransition(_ transitionID: UUID?, profileID: UUID) {
        guard let transitionID, endpointTransitionIDs[profileID] == transitionID else { return }
        endpointTransitionIDs.removeValue(forKey: profileID)
    }

    private func supersedeActiveRefresh() {
        activeRefreshID = nil
        isRefreshing = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
    }

    private func hasUsableCredentials(for profileID: UUID) -> Bool {
        credentials(for: profileID).map(credentialsAreUsable) ?? false
    }

    private func credentialsAreUsable(_ credentials: Credentials) -> Bool {
        !credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credentials.password.isEmpty
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

    private func startPolling(refreshImmediately: Bool = true) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            if !refreshImmediately {
                guard let interval = self?.preferences.refreshInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
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
