import Foundation

@MainActor
final class UsageStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var phase: UsagePhase = .loading
    private(set) var isRefreshing = false
    var onChange: (() -> Void)?

    private let client: any UsageFetching
    private let credentialStore: CredentialStore
    private let preferencesStore: PreferencesStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private var credentials: Credentials?
    private(set) var preferences: UserPreferences
    private(set) var settingsMessage: String?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(
        client: any UsageFetching = APIClient(),
        credentialStore: CredentialStore = CredentialStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager()
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.preferencesStore = preferencesStore
        self.launchAtLoginManager = launchAtLoginManager
        preferences = preferencesStore.load()

        do {
            credentials = try credentialStore.load()
            phase = credentials == nil ? .needsConfiguration : .loading
        } catch {
            phase = .failed(error.localizedDescription)
        }
        applyLaunchAtLoginPreference()
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
    }

    func currentCredentials() -> Credentials? { credentials }

    var needsConfiguration: Bool { credentials == nil }

    var launchAtLoginStatus: String {
        launchAtLoginManager.statusDescription
    }

    func savePreferences(
        email: String,
        password: String,
        refreshInterval: TimeInterval,
        launchAtLogin: Bool,
        showAPIKeyDetails: Bool,
        showMetricCards: Bool
    ) async throws {
        let value = Credentials(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        let updatedPreferences = UserPreferences(
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin,
            showAPIKeyDetails: showAPIKeyDetails,
            showMetricCards: showMetricCards
        )
        guard !value.email.isEmpty else { throw PreferencesError.emptyEmail }
        guard !value.password.isEmpty else { throw PreferencesError.emptyPassword }

        try credentialStore.save(value)
        preferencesStore.save(updatedPreferences)
        credentials = value
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

        phase = .loading
        startPolling()
        onChange?()
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let credentials else {
            if phase != .needsConfiguration {
                phase = .needsConfiguration
                onChange?()
            }
            return
        }

        isRefreshing = true
        onChange?()
        defer {
            isRefreshing = false
            onChange?()
        }

        do {
            let usage = try await client.fetchUsage(credentials: credentials)
            snapshot = UsageSnapshot(
                weeklyUsage: usage.weeklyUsage,
                accountMetrics: usage.accountMetrics,
                keys: usage.keys
            )
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
            try launchAtLoginManager.setEnabled(
                preferences.launchAtLogin,
                refreshRegistration: needsRefresh
            )
            if preferences.launchAtLogin {
                preferencesStore.markLaunchRegistrationCurrent()
            }
            settingsMessage = launchAtLoginManager.statusDescription
        } catch {
            settingsMessage = "开机启动设置失败：\(error.localizedDescription)"
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let apiError = error as? APIClientError {
            switch apiError {
            case .httpStatus(401), .httpStatus(403):
                return "登录已失效，请检查账号和密码"
            default:
                return apiError.localizedDescription
            }
        }
        if error is DecodingError {
            return "接口数据格式发生变化"
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "网络连接失败，稍后会自动重试"
        }
        return error.localizedDescription
    }
}

enum PreferencesError: LocalizedError {
    case emptyEmail
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .emptyEmail:
            return "接口账号不能为空"
        case .emptyPassword:
            return "密码不能为空"
        }
    }
}
