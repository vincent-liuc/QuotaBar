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
    private let launchAtLoginManager: LaunchAtLoginManager
    private(set) var preferences: UserPreferences
    private(set) var settingsMessage: String?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(
        client: any UsageFetching = APIClient(),
        credentialStore: CredentialStore = CredentialStore(),
        profileStore: StationProfileStore = StationProfileStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager()
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.profileStore = profileStore
        self.preferencesStore = preferencesStore
        self.launchAtLoginManager = launchAtLoginManager
        preferences = preferencesStore.load()
        loadProfilesAndMigrate()
        applyLaunchAtLoginPreference()
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
    }

    var activeProfile: StationProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    var needsConfiguration: Bool {
        guard let profile = activeProfile else { return true }
        return (try? credentialStore.load(for: profile.id)) == nil
    }

    var launchAtLoginStatus: String { launchAtLoginManager.statusDescription }

    func credentials(for profileID: UUID) -> Credentials? {
        try? credentialStore.load(for: profileID)
    }

    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult {
        try validate(credentials)
        return try await client.testConnection(profile: profile.validated(), credentials: credentials)
    }

    func saveConfiguration(
        profile: StationProfile,
        credentials: Credentials,
        refreshInterval: TimeInterval,
        launchAtLogin: Bool,
        showAPIKeyDetails: Bool,
        showMetricCards: Bool,
        makeActive: Bool = true
    ) async throws {
        settingsMessage = nil
        try validate(credentials)
        var validatedProfile = try profile.validated()
        let testResult = try await client.testConnection(profile: validatedProfile, credentials: credentials)
        validatedProfile.capabilities = testResult.capabilities
        validatedProfile.lastCheckedAt = testResult.checkedAt
        if case .manual(let id) = validatedProfile.subscriptionSelection,
           !testResult.subscriptions.contains(where: { $0.id == id && $0.status == "active" }) {
            throw APIClientError.missingSubscription
        }

        let updatedPreferences = UserPreferences(
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin,
            showAPIKeyDetails: showAPIKeyDetails,
            showMetricCards: showMetricCards
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
            try launchAtLoginManager.setEnabled(launchAtLogin)
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
        guard !isRefreshing else { return }
        guard let profile = activeProfile,
              let credentials = (try? credentialStore.load(for: profile.id)) ?? nil else {
            phase = .needsConfiguration
            onChange?()
            return
        }

        isRefreshing = true
        onChange?()
        defer { isRefreshing = false; onChange?() }
        do {
            let usage = try await client.fetchUsage(profile: profile, credentials: credentials)
            snapshot = UsageSnapshot(
                weeklyUsage: usage.weeklyUsage,
                accountMetrics: usage.accountMetrics,
                keys: usage.keys
            )
            updateCapabilities(usage.capabilities, for: profile.id)
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(Self.userFacingMessage(for: error))
        }
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    private func loadProfilesAndMigrate() {
        let state = profileStore.load()
        if !state.profiles.isEmpty {
            profiles = state.profiles
            activeProfileID = state.activeProfileID ?? state.profiles.first?.id
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

    private func updateCapabilities(_ capabilities: Set<StationCapability>, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].capabilities != capabilities else { return }
        profiles[index].capabilities = capabilities
        profiles[index].lastCheckedAt = Date()
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

    private static func userFacingMessage(for error: Error) -> String {
        if let apiError = error as? APIClientError {
            switch apiError {
            case .httpStatus(401), .httpStatus(403): return "登录已失效，请检查账号和密码"
            default: return apiError.localizedDescription
            }
        }
        if error is DecodingError { return "接口数据格式发生变化" }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "网络连接失败，稍后会自动重试" }
        return error.localizedDescription
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
