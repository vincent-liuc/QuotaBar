import Foundation

enum APIClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case api(code: Int, message: String)
    case missingSubscription
    case incompatibleStation
    case authenticationFailed
    case twoFactorAuthenticationRequired
    case interactiveAuthenticationRequired
    case backendModeRestricted
    case loginRejected(Int)
    case stationProbeRejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case .httpStatus(let status): return "服务器请求失败（HTTP \(status)）"
        case .api(_, let message): return message
        case .missingSubscription: return "没有找到可用的订阅周额度"
        case .incompatibleStation: return "该地址不是可识别的 Sub2API 兼容站点"
        case .authenticationFailed: return "登录信息有误，请调整后再试"
        case .twoFactorAuthenticationRequired: return "当前账户启用了两步验证，QuotaBar 暂不支持此登录方式"
        case .interactiveAuthenticationRequired: return "当前站点启用了人机验证，QuotaBar 暂不支持此登录方式"
        case .backendModeRestricted: return "当前站点仅允许管理员登录，请更换管理员账户后再试"
        case .loginRejected(let status): return "登录请求被站点拒绝（HTTP \(status)），请检查账户格式或站点认证策略"
        case .stationProbeRejected(let status): return "站点公共接口拒绝访问（HTTP \(status)），请检查地址、反向代理或访问策略"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData
    func resetAPIKeyQuota(profile: StationProfile, credentials: Credentials, keyID: Int) async throws
    func testStation(profile: StationProfile) async throws
    func testLogin(profile: StationProfile, credentials: Credentials) async throws
    func discoverAccount(profile: StationProfile, credentials: Credentials) async throws -> AccountDiscoveryResult
    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult
    func invalidateSession() async
}

extension UsageFetching {
    func discoverAccount(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> AccountDiscoveryResult {
        try await testLogin(profile: profile, credentials: credentials)
        return AccountDiscoveryResult(subscriptions: .unsupported)
    }
}

actor APIClient: NSObject, UsageFetching, URLSessionTaskDelegate {
    private var session: URLSession!
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var tokenIdentity: TokenIdentity?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    init(session: URLSession) {
        self.session = session
        super.init()
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        let profile = try profile.validated()
        let token = try await validToken(profile: profile, credentials: credentials)
        do {
            return try await fetchUsage(profile: profile, token: token)
        } catch APIClientError.httpStatus(401), APIClientError.httpStatus(403) {
            invalidateToken()
            let refreshedToken = try await validToken(profile: profile, credentials: credentials)
            return try await fetchUsage(profile: profile, token: refreshedToken)
        }
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {
        try Task.checkCancellation()
        let profile = try profile.validated()
        let token = try await validToken(profile: profile, credentials: credentials)
        try Task.checkCancellation()
        do {
            try await resetAPIKeyQuota(profile: profile, token: token, keyID: keyID)
        } catch APIClientError.httpStatus(401), APIClientError.httpStatus(403) {
            invalidateToken()
            let refreshedToken = try await validToken(profile: profile, credentials: credentials)
            try await resetAPIKeyQuota(profile: profile, token: refreshedToken, keyID: keyID)
        }
    }

    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult {
        let profile = try profile.validated()
        let token = try await authenticate(profile: profile, credentials: credentials).accessToken
        let keys = try await fetchAllKeys(profile: profile, token: token)
        var capabilities: Set<StationCapability> = []
        if keys.contains(where: { $0.currentConcurrency != nil }) { capabilities.insert(.concurrency) }

        let subscriptionResult = try? await fetchSubscriptions(profile: profile, token: token)
        let subscriptions = subscriptionResult ?? []
        if subscriptionResult != nil { capabilities.insert(.subscriptions) }
        if (try? await fetchAccountMetrics(profile: profile, token: token)) != nil {
            capabilities.insert(.accountMetrics)
        }
        let supportsDailyUsage: Bool
        if keys.isEmpty {
            supportsDailyUsage = false
        } else {
            supportsDailyUsage = (try? await fetchTodayUsage(
                profile: profile,
                token: token,
                keyIDs: keys.map(\.id)
            )) != nil
        }
        if supportsDailyUsage {
            capabilities.insert(.apiKeyDailyUsage)
        }
        if (try? await fetchUsageHistory(profile: profile, token: token)) != nil {
            capabilities.insert(.usageHistory)
        }

        return ConnectionTestResult(
            capabilities: capabilities,
            subscriptions: subscriptionOptions(from: subscriptions),
            checkedAt: Date()
        )
    }

    func testStation(profile: StationProfile) async throws {
        let profile = try profile.validated()
        let request = URLRequest(url: try endpoint(profile, "settings/public"))
        do {
            let envelope: APIEnvelope<PublicSettingsData> = try await send(request)
            guard envelope.data.hasSub2APIFingerprint else {
                throw APIClientError.incompatibleStation
            }
        } catch APIClientError.httpStatus(let status)
            where [400, 401, 403, 404, 405, 410, 422].contains(status) {
            if [404, 405, 410].contains(status) {
                throw APIClientError.incompatibleStation
            }
            throw APIClientError.stationProbeRejected(status)
        }
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {
        _ = try await authenticate(profile: profile.validated(), credentials: credentials)
    }

    func discoverAccount(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> AccountDiscoveryResult {
        let profile = try profile.validated()
        let token = try await authenticate(profile: profile, credentials: credentials).accessToken
        do {
            let records = try await fetchSubscriptions(profile: profile, token: token)
            return AccountDiscoveryResult(subscriptions: .available(subscriptionOptions(from: records)))
        } catch is CancellationError {
            throw CancellationError()
        } catch APIClientError.httpStatus(let status) where [404, 405, 410].contains(status) {
            return AccountDiscoveryResult(subscriptions: .unsupported)
        } catch {
            return AccountDiscoveryResult(subscriptions: .failed(error.localizedDescription))
        }
    }

    func invalidateSession() {
        invalidateToken()
    }

    private func fetchUsage(profile: StationProfile, token: String) async throws -> UsageData {
        let keys = try await fetchAllKeys(profile: profile, token: token).filter(\.isVisible)
        async let subscriptions = optional { try await self.fetchSubscriptions(profile: profile, token: token) }
        async let accountMetrics = optional { try await self.fetchAccountMetrics(profile: profile, token: token) }
        async let todayUsage = optional {
            try await self.fetchTodayUsage(profile: profile, token: token, keyIDs: keys.map(\.id))
        }
        async let usageHistory = optional {
            try await self.fetchUsageHistory(profile: profile, token: token)
        }

        let subscriptionResult = await subscriptions
        let metricsResult = await accountMetrics
        let usageResult = await todayUsage
        let historyResult = await usageHistory
        let weeklyUsage = subscriptionResult.flatMap { selectWeeklyUsage($0, selection: profile.subscriptionSelection) }
        let keysWithUsage = keys.map { key in
            var updated = key
            updated.todayActualCost = usageResult.map { $0[key.id] ?? 0 }
            return updated
        }
        var capabilities: Set<StationCapability> = []
        if subscriptionResult != nil { capabilities.insert(.subscriptions) }
        if metricsResult != nil { capabilities.insert(.accountMetrics) }
        if usageResult != nil { capabilities.insert(.apiKeyDailyUsage) }
        if keys.contains(where: { $0.currentConcurrency != nil }) { capabilities.insert(.concurrency) }
        if historyResult != nil { capabilities.insert(.usageHistory) }
        return UsageData(
            weeklyUsage: weeklyUsage,
            accountMetrics: metricsResult,
            keys: keysWithUsage,
            usageRecords: historyResult,
            subscriptionOptions: subscriptionResult.map { subscriptionOptions(from: $0) },
            capabilities: capabilities
        )
    }

    private func optional<T: Sendable>(_ operation: () async throws -> T) async -> T? {
        do { return try await operation() } catch { return nil }
    }

    private func selectWeeklyUsage(
        _ subscriptions: [SubscriptionRecord],
        selection: SubscriptionSelection
    ) -> WeeklyUsage? {
        let subscription: SubscriptionRecord?
        switch selection {
        case .automatic:
            let active = subscriptions.filter { $0.status == "active" }
            subscription = active.first(where: { $0.weeklyLimitUSD != nil })
                ?? active.first
                ?? subscriptions.first(where: { $0.weeklyLimitUSD != nil })
                ?? subscriptions.first
        case .manual(let id):
            subscription = subscriptions.first { $0.id == id && $0.status == "active" }
        }
        guard let subscription, let total = subscription.weeklyLimitUSD else { return nil }
        return WeeklyUsage(
            subscriptionID: subscription.id,
            used: max(subscription.weeklyUsageUSD ?? 0, 0),
            total: max(total, 0),
            resetAt: WeeklyResetCalculator.nextReset(
                windowStart: subscription.weeklyWindowStart,
                expiresAt: subscription.expiresAt
            )
        )
    }

    private func validToken(profile: StationProfile, credentials: Credentials) async throws -> String {
        let identity = TokenIdentity(profile: profile, credentials: credentials)
        let hasTimeRemaining = tokenExpiresAt.map { $0 > Date().addingTimeInterval(30) } ?? true
        if let cachedToken, tokenIdentity == identity, hasTimeRemaining { return cachedToken }

        return try await authenticate(profile: profile, credentials: credentials).accessToken
    }

    private func authenticate(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> AuthenticatedLogin {
        let loginData = try await login(profile: profile, credentials: credentials)
        cachedToken = loginData.accessToken
        tokenIdentity = TokenIdentity(profile: profile, credentials: credentials)
        tokenExpiresAt = loginData.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return loginData
    }

    private func invalidateToken() {
        cachedToken = nil
        tokenExpiresAt = nil
        tokenIdentity = nil
    }

    private func login(profile: StationProfile, credentials: Credentials) async throws -> AuthenticatedLogin {
        var request = URLRequest(url: try endpoint(profile, "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginPayload(email: credentials.email, password: credentials.password))
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        let envelope = try? JSONDecoder().decode(LoginResponseEnvelope.self, from: data)
        guard (200...299).contains(response.statusCode) else {
            throw classifyLoginFailure(status: response.statusCode, envelope: envelope)
        }
        guard let envelope else { throw APIClientError.invalidResponse }
        guard envelope.code == 0 else {
            throw classifyLoginFailure(status: envelope.code, envelope: envelope)
        }
        guard let loginData = envelope.data else { throw APIClientError.invalidResponse }
        if loginData.requires2FA == true {
            throw APIClientError.twoFactorAuthenticationRequired
        }
        guard let token = loginData.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw APIClientError.invalidResponse
        }
        return AuthenticatedLogin(
            accessToken: token,
            expiresIn: loginData.expiresIn,
            tokenType: loginData.tokenType
        )
    }

    private func classifyLoginFailure(
        status: Int,
        envelope: LoginResponseEnvelope?
    ) -> APIClientError {
        let reason = envelope?.reason?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let message = envelope?.message.lowercased() ?? ""
        if reason.contains("CAPTCHA") || reason.contains("TURNSTILE") {
            return .interactiveAuthenticationRequired
        }
        if reason == "BACKEND_MODE_ADMIN_ONLY" {
            return .backendModeRestricted
        }
        if ["INVALID_CREDENTIALS", "USER_NOT_ACTIVE"].contains(reason)
            || message.contains("invalid credential")
            || message.contains("invalid email or password")
            || message.contains("user is not active") {
            return .authenticationFailed
        }
        if status == 401 { return .authenticationFailed }
        if [400, 403, 422].contains(status) { return .loginRejected(status) }
        return .httpStatus(status)
    }

    private func subscriptionOptions(from records: [SubscriptionRecord]) -> [SubscriptionOption] {
        records.compactMap {
            guard let id = $0.id else { return nil }
            return SubscriptionOption(
                id: id,
                name: $0.name ?? "订阅 #\(id)",
                status: $0.status,
                hasWeeklyLimit: $0.weeklyLimitUSD != nil
            )
        }
    }

    private func fetchAllKeys(profile: StationProfile, token: String) async throws -> [UsageKey] {
        let requestedPageSize = 100
        var page = 1
        var receivedCount = 0
        var orderedKeys: [UsageKey] = []
        var keyIndexes: [Int: Int] = [:]
        while true {
            let data = try await fetchKeyPage(profile: profile, token: token, page: page, pageSize: requestedPageSize)
            receivedCount += data.items.count
            for key in data.items {
                if let index = keyIndexes[key.id] { orderedKeys[index] = key }
                else { keyIndexes[key.id] = orderedKeys.count; orderedKeys.append(key) }
            }
            if let pages = data.pages {
                if page >= pages { break }
            } else if receivedCount >= data.total || data.items.isEmpty {
                break
            } else if data.items.count < max(data.pageSize ?? requestedPageSize, 1) {
                break
            }
            page += 1
        }
        return orderedKeys
    }

    private func fetchSubscriptions(profile: StationProfile, token: String) async throws -> [SubscriptionRecord] {
        var components = URLComponents(url: try endpoint(profile, "subscriptions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "timezone", value: profile.timezone)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let envelope: APIEnvelope<[SubscriptionRecord]> = try await send(request)
        return envelope.data
    }

    private func fetchKeyPage(
        profile: StationProfile, token: String, page: Int, pageSize: Int
    ) async throws -> KeyListData {
        var components = URLComponents(url: try endpoint(profile, "keys"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: "created_at"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "timezone", value: profile.timezone)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let envelope: APIEnvelope<KeyListData> = try await send(request)
        return envelope.data
    }

    private func fetchTodayUsage(
        profile: StationProfile, token: String, keyIDs: [Int]
    ) async throws -> [Int: Double] {
        guard !keyIDs.isEmpty else { return [:] }
        var request = URLRequest(url: try endpoint(profile, "usage/dashboard/api-keys-usage"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(APIKeyUsagePayload(apiKeyIDs: keyIDs))
        let envelope: APIEnvelope<APIKeyUsageData> = try await send(request)
        var result: [Int: Double] = [:]
        for stat in envelope.data.stats.values { result[stat.apiKeyID] = max(stat.todayActualCost, 0) }
        return result
    }

    private func resetAPIKeyQuota(profile: StationProfile, token: String, keyID: Int) async throws {
        try Task.checkCancellation()
        var request = URLRequest(url: try endpoint(profile, "keys/\(keyID)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ResetAPIKeyQuotaPayload())
        try Task.checkCancellation()
        let _: APIEnvelope<IgnoredAPIData> = try await send(request)
    }

    private func fetchAccountMetrics(profile: StationProfile, token: String) async throws -> AccountMetrics {
        var request = URLRequest(url: try endpoint(profile, "usage/dashboard/stats"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let envelope: APIEnvelope<DashboardStats> = try await send(request)
        return AccountMetrics(
            totalTokens: max(envelope.data.totalTokens, 0),
            totalActualCost: max(envelope.data.totalActualCost, 0)
        )
    }

    private func fetchUsageHistory(profile: StationProfile, token: String) async throws -> [UsageRecord] {
        let range = try UsageHistoryDateRange(timezone: profile.timezone)
        var components = URLComponents(url: try endpoint(profile, "usage"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "50"),
            URLQueryItem(name: "start_date", value: range.startDate),
            URLQueryItem(name: "end_date", value: range.endDate),
            URLQueryItem(name: "sort_by", value: "created_at"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "timezone", value: profile.timezone)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let envelope: APIEnvelope<UsageRecordListData> = try await send(request)
        return envelope.data.items
    }

    private func endpoint(_ profile: StationProfile, _ path: String) throws -> URL {
        guard let baseURL = profile.apiBaseURL else { throw StationProfileError.invalidServiceURL }
        return baseURL.appending(path: path)
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<Value> {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw APIClientError.httpStatus(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        do {
            let envelope = try decoder.decode(APIEnvelope<Value>.self, from: data)
            guard envelope.code == 0 else { throw APIClientError.api(code: envelope.code, message: envelope.message) }
            return envelope
        } catch let error as APIClientError {
            throw error
        } catch {
            throw APIClientError.invalidResponse
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard task.currentRequest?.url?.origin == request.url?.origin else { return nil }
        return request
    }
}

private struct AuthenticatedLogin: Sendable {
    let accessToken: String
    let expiresIn: Int?
    let tokenType: String?
}

private struct LoginResponseEnvelope: Decodable, Sendable {
    let code: Int
    let message: String
    let reason: String?
    let data: LoginData?
}

enum WeeklyResetCalculator {
    static let period: TimeInterval = 7 * 24 * 60 * 60

    static func nextReset(
        windowStart: Date?,
        expiresAt: Date?,
        now: Date = Date()
    ) -> Date? {
        guard let windowStart else { return nil }
        let elapsed = max(now.timeIntervalSince(windowStart), 0)
        let completedPeriods = floor(elapsed / period)
        let candidate = windowStart.addingTimeInterval((completedPeriods + 1) * period)
        if let expiresAt, candidate >= expiresAt { return nil }
        return candidate
    }
}

struct UsageHistoryDateRange: Equatable, Sendable {
    let startDate: String
    let endDate: String

    init(timezone: String, now: Date = Date()) throws {
        guard let timeZone = TimeZone(identifier: timezone) else {
            throw StationProfileError.invalidTimezone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
            throw APIClientError.invalidResponse
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        startDate = formatter.string(from: yesterday)
        endDate = formatter.string(from: now)
    }
}

private struct TokenIdentity: Equatable, Sendable {
    let profileID: UUID
    let baseURL: String
    let credentials: Credentials

    init(profile: StationProfile, credentials: Credentials) {
        profileID = profile.id
        baseURL = profile.apiBaseURL?.absoluteString ?? ""
        self.credentials = credentials
    }
}

private extension URL {
    var origin: String? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return nil }
        return "\(scheme.lowercased())://\(host.lowercased()):\(components.port ?? (scheme == "https" ? 443 : 80))"
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(
            in: try decoder.singleValueContainer(),
            debugDescription: "Invalid ISO-8601 date: \(value)"
        )
    }
}
