import Foundation

enum APIClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case api(code: Int, message: String)
    case missingSubscription
    case incompatibleStation
    case authenticationFailed
    case twoFactorAuthenticationRequired
    case turnstileRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case .httpStatus(let status): return "服务器请求失败（HTTP \(status)）"
        case .api(_, let message): return message
        case .missingSubscription: return "没有找到可用的订阅周额度"
        case .incompatibleStation: return "该地址不是可识别的兼容站点"
        case .authenticationFailed: return "登录信息有误，请调整后再试"
        case .twoFactorAuthenticationRequired: return "该账户启用了两步验证，暂不支持直接登录，请先关闭两步验证或使用未启用 2FA 的账号"
        case .turnstileRequired: return "该站点启用了 Turnstile 人机验证，桌面应用无法自动完成登录"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData
    func resetAPIKeyQuota(profile: StationProfile, credentials: Credentials, keyID: Int) async throws
    func testStation(profile: StationProfile) async throws
    func testLogin(profile: StationProfile, credentials: Credentials) async throws
    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult
    func invalidateSession() async
}

private struct AuthenticatedSession: Equatable, Sendable {
    let token: String?
    let userID: Int?
}

actor APIClient: NSObject, UsageFetching, URLSessionTaskDelegate {
    private var session: URLSession!
    private var cachedSession: AuthenticatedSession?
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
        let authenticated = try await validSession(profile: profile, credentials: credentials)
        do {
            return try await fetchUsage(profile: profile, authenticated: authenticated)
        } catch APIClientError.httpStatus(401), APIClientError.httpStatus(403) {
            invalidateSessionCache()
            let refreshed = try await validSession(profile: profile, credentials: credentials)
            return try await fetchUsage(profile: profile, authenticated: refreshed)
        }
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {
        let profile = try profile.validated()
        guard profile.kind == .sub2API else { throw APIClientError.incompatibleStation }
        let authenticated = try await validSession(profile: profile, credentials: credentials)
        let token = try bearerToken(authenticated)
        do {
            try await resetAPIKeyQuota(profile: profile, token: token, keyID: keyID)
        } catch APIClientError.httpStatus(401), APIClientError.httpStatus(403) {
            invalidateSessionCache()
            let refreshed = try await validSession(profile: profile, credentials: credentials)
            try await resetAPIKeyQuota(profile: profile, token: bearerToken(refreshed), keyID: keyID)
        }
    }

    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult {
        let profile = try profile.validated()
        let authenticated = try await login(profile: profile, credentials: credentials)
        switch profile.kind {
        case .sub2API:
            let token = try bearerToken(authenticated)
            let keys = try await fetchAllKeys(profile: profile, token: token)
            var capabilities: Set<StationCapability> = []
            if keys.contains(where: { $0.currentConcurrency != nil }) { capabilities.insert(.concurrency) }
            let subscriptionResult = try? await fetchSubscriptions(profile: profile, token: token)
            let subscriptions = subscriptionResult ?? []
            if subscriptionResult != nil { capabilities.insert(.subscriptions) }
            if (try? await fetchAccountMetrics(profile: profile, token: token)) != nil {
                capabilities.insert(.accountMetrics)
            }
            if !keys.isEmpty,
               (try? await fetchTodayUsage(profile: profile, token: token, keyIDs: keys.map(\.id))) != nil {
                capabilities.insert(.apiKeyDailyUsage)
            }
            if (try? await fetchUsageHistory(profile: profile, token: token)) != nil {
                capabilities.insert(.usageHistory)
            }
            return ConnectionTestResult(
                capabilities: capabilities,
                subscriptions: subscriptions.compactMap {
                    guard let id = $0.id else { return nil }
                    return SubscriptionOption(
                        id: id,
                        name: $0.name ?? "订阅 #\(id)",
                        status: $0.status,
                        hasWeeklyLimit: $0.weeklyLimitUSD != nil
                    )
                },
                checkedAt: Date()
            )
        case .newAPI:
            let usage = try await fetchNewAPIUsage(profile: profile, authenticated: authenticated)
            return ConnectionTestResult(
                capabilities: usage.capabilities,
                subscriptions: [],
                checkedAt: Date()
            )
        }
    }

    func testStation(profile: StationProfile) async throws {
        let profile = try profile.validated()
        switch profile.kind {
        case .sub2API:
            var request = URLRequest(url: try endpoint(profile, "auth/login"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
            if response.statusCode == 408 || response.statusCode == 429 || response.statusCode >= 500 {
                throw APIClientError.httpStatus(response.statusCode)
            }
            guard [400, 401, 403, 422].contains(response.statusCode),
                  let envelope = try? JSONDecoder().decode(ProbeEnvelope.self, from: data),
                  envelope.code == response.statusCode,
                  !envelope.message.isEmpty else {
                throw APIClientError.incompatibleStation
            }
        case .newAPI:
            let status = try await fetchNewAPIStatus(profile: profile)
            if status.turnstileCheck { throw APIClientError.turnstileRequired }
        }
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {
        _ = try await login(profile: profile.validated(), credentials: credentials)
    }

    func invalidateSession() {
        invalidateSessionCache()
    }

    private func fetchUsage(profile: StationProfile, authenticated: AuthenticatedSession) async throws -> UsageData {
        switch profile.kind {
        case .sub2API:
            return try await fetchSub2APIUsage(profile: profile, token: bearerToken(authenticated))
        case .newAPI:
            return try await fetchNewAPIUsage(profile: profile, authenticated: authenticated)
        }
    }

    private func fetchSub2APIUsage(profile: StationProfile, token: String) async throws -> UsageData {
        let keys = try await fetchAllKeys(profile: profile, token: token).filter(\.isVisible)
        async let subscriptions = optional { try await self.fetchSubscriptions(profile: profile, token: token) }
        async let accountMetrics = optional { try await self.fetchAccountMetrics(profile: profile, token: token) }
        async let todayUsage = optional {
            try await self.fetchTodayUsage(profile: profile, token: token, keyIDs: keys.map(\.id))
        }
        async let usageHistory = optional { try await self.fetchUsageHistory(profile: profile, token: token) }

        let subscriptionResult = await subscriptions
        let metricsResult = await accountMetrics
        let usageResult = await todayUsage
        let historyResult = await usageHistory
        let selectedSubscription = subscriptionResult.flatMap {
            selectSubscription($0, selection: profile.subscriptionSelection)
        }
        let weeklyUsage = selectedSubscription.flatMap(makeWeeklyUsage)
        let dailyUsage = selectedSubscription.flatMap(makeDailyUsage)
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
            dailyUsage: dailyUsage,
            accountMetrics: metricsResult,
            keys: keysWithUsage,
            usageRecords: historyResult,
            capabilities: capabilities
        )
    }

    private func fetchNewAPIUsage(
        profile: StationProfile,
        authenticated: AuthenticatedSession
    ) async throws -> UsageData {
        let status = try await fetchNewAPIStatus(profile: profile)
        if status.turnstileCheck { throw APIClientError.turnstileRequired }
        let user = try await fetchNewAPIUser(profile: profile, authenticated: authenticated)
        let tokens = try await fetchNewAPITokens(profile: profile, authenticated: authenticated)
        let keys = tokens.map { makeUsageKey($0, quotaPerUnit: status.quotaPerUnit) }.filter(\.isVisible)
        async let dataPoints = optional {
            try await self.fetchNewAPIData(profile: profile, authenticated: authenticated)
        }
        async let todayUsage = optional {
            try await self.fetchNewAPITodayUsage(
                profile: profile,
                authenticated: authenticated,
                keys: keys,
                quotaPerUnit: status.quotaPerUnit
            )
        }
        async let usageHistory = optional {
            try await self.fetchNewAPIUsageHistory(
                profile: profile,
                authenticated: authenticated,
                quotaPerUnit: status.quotaPerUnit
            )
        }

        let points = await dataPoints
        let usageResult = await todayUsage
        let historyResult = await usageHistory
        let keysWithUsage = keys.map { key in
            var updated = key
            updated.todayActualCost = usageResult?[key.id]
            return updated
        }
        let totalTokens = points?.reduce(Int64(0)) { $0 + $1.tokenUsed } ?? 0
        let historicalConsumption = max(user.usedQuota / max(status.quotaPerUnit, 1), 0)
        let balance = max(user.quota / max(status.quotaPerUnit, 1), 0)
        let metrics = AccountMetrics(
            totalTokens: totalTokens,
            totalActualCost: historicalConsumption,
            balance: balance,
            requestCount: max(user.requestCount, 0),
            tokensPeriod: .today
        )
        // New API account quota is the remaining balance plus historical consumption.
        // Token-level limits are still shown in the API key details below.
        let accountPool = WeeklyUsage(
            kind: .accountPool,
            used: historicalConsumption,
            total: balance + historicalConsumption
        )
        var capabilities: Set<StationCapability> = [.accountMetrics]
        if usageResult != nil { capabilities.insert(.apiKeyDailyUsage) }
        if historyResult != nil { capabilities.insert(.usageHistory) }
        return UsageData(
            weeklyUsage: accountPool,
            dailyUsage: nil,
            accountMetrics: metrics,
            keys: keysWithUsage,
            usageRecords: historyResult,
            capabilities: capabilities
        )
    }

    private func optional<T: Sendable>(_ operation: () async throws -> T) async -> T? {
        do { return try await operation() } catch { return nil }
    }

    private func selectSubscription(
        _ subscriptions: [SubscriptionRecord],
        selection: SubscriptionSelection
    ) -> SubscriptionRecord? {
        switch selection {
        case .automatic:
            let active = subscriptions.filter { $0.status == "active" }
            return active.first(where: { $0.weeklyLimitUSD != nil })
                ?? active.first
                ?? subscriptions.first(where: { $0.weeklyLimitUSD != nil })
                ?? subscriptions.first
        case .manual(let id):
            return subscriptions.first { $0.id == id && $0.status == "active" }
        }
    }

    private func makeWeeklyUsage(_ subscription: SubscriptionRecord) -> WeeklyUsage? {
        guard let total = subscription.weeklyLimitUSD else { return nil }
        return WeeklyUsage(
            kind: .weekly,
            subscriptionID: subscription.id,
            used: max(subscription.weeklyUsageUSD ?? 0, 0),
            total: max(total, 0),
            resetAt: WeeklyResetCalculator.nextReset(
                windowStart: subscription.weeklyWindowStart,
                expiresAt: subscription.expiresAt
            )
        )
    }

    private func makeDailyUsage(_ subscription: SubscriptionRecord) -> DailyUsage? {
        guard let total = subscription.dailyLimitUSD else { return nil }
        return DailyUsage(
            subscriptionID: subscription.id,
            subscriptionName: subscription.name,
            used: max(subscription.dailyUsageUSD ?? 0, 0),
            total: max(total, 0),
            resetAt: DailyResetCalculator.nextReset(
                windowStart: subscription.dailyWindowStart,
                expiresAt: subscription.expiresAt
            )
        )
    }

    private func validSession(profile: StationProfile, credentials: Credentials) async throws -> AuthenticatedSession {
        let identity = TokenIdentity(profile: profile, credentials: credentials)
        let hasTimeRemaining = tokenExpiresAt.map { $0 > Date().addingTimeInterval(30) } ?? true
        if let cachedSession, tokenIdentity == identity, hasTimeRemaining { return cachedSession }
        let authenticated = try await login(profile: profile, credentials: credentials)
        cachedSession = authenticated
        tokenIdentity = identity
        tokenExpiresAt = profile.kind == .sub2API ? Date().addingTimeInterval(3600) : nil
        return authenticated
    }

    private func invalidateSessionCache() {
        cachedSession = nil
        tokenExpiresAt = nil
        tokenIdentity = nil
    }

    private func login(profile: StationProfile, credentials: Credentials) async throws -> AuthenticatedSession {
        switch profile.kind {
        case .sub2API:
            var request = URLRequest(url: try endpoint(profile, "auth/login"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(LoginPayload(email: credentials.email, password: credentials.password))
            do {
                let envelope: APIEnvelope<LoginData> = try await send(request)
                return AuthenticatedSession(token: envelope.data.accessToken, userID: nil)
            } catch APIClientError.httpStatus(400), APIClientError.httpStatus(401),
                    APIClientError.httpStatus(403), APIClientError.httpStatus(422) {
                throw APIClientError.authenticationFailed
            } catch APIClientError.api(let code, let message)
                where code == 400 || code == 401 || code == 403 || code == 422
                    || message.lowercased().contains("invalid credential")
                    || message.lowercased().contains("invalid email or password") {
                throw APIClientError.authenticationFailed
            }
        case .newAPI:
            clearCookies(for: profile)
            var components = URLComponents(url: try endpoint(profile, "user/login"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "turnstile", value: "")]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(NewAPILoginPayload(username: credentials.email, password: credentials.password))
            do {
                let envelope: NewAPIEnvelope<NewAPILoginData> = try await sendNewAPI(request)
                guard let data = envelope.data else { throw APIClientError.invalidResponse }
                if data.require2FA == true { throw APIClientError.twoFactorAuthenticationRequired }
                let token = data.token?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AuthenticatedSession(token: token?.isEmpty == false ? token : nil, userID: data.id)
            } catch APIClientError.httpStatus(400), APIClientError.httpStatus(401),
                    APIClientError.httpStatus(403), APIClientError.httpStatus(422) {
                throw APIClientError.authenticationFailed
            } catch APIClientError.api(_, let message)
                where DashboardIssue.authenticationMessage(message) {
                throw APIClientError.authenticationFailed
            }
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
        let request = authenticatedRequest(URLRequest(url: components.url!), token: token)
        let envelope: APIEnvelope<[SubscriptionRecord]> = try await send(request)
        return envelope.data
    }

    private func fetchKeyPage(profile: StationProfile, token: String, page: Int, pageSize: Int) async throws -> KeyListData {
        var components = URLComponents(url: try endpoint(profile, "keys"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: "created_at"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "timezone", value: profile.timezone)
        ]
        let request = authenticatedRequest(URLRequest(url: components.url!), token: token)
        let envelope: APIEnvelope<KeyListData> = try await send(request)
        return envelope.data
    }

    private func fetchTodayUsage(profile: StationProfile, token: String, keyIDs: [Int]) async throws -> [Int: Double] {
        guard !keyIDs.isEmpty else { return [:] }
        var request = authenticatedRequest(URLRequest(url: try endpoint(profile, "usage/dashboard/api-keys-usage")), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(APIKeyUsagePayload(apiKeyIDs: keyIDs))
        let envelope: APIEnvelope<APIKeyUsageData> = try await send(request)
        var result: [Int: Double] = [:]
        for stat in envelope.data.stats.values { result[stat.apiKeyID] = max(stat.todayActualCost, 0) }
        return result
    }

    private func resetAPIKeyQuota(profile: StationProfile, token: String, keyID: Int) async throws {
        var request = authenticatedRequest(URLRequest(url: try endpoint(profile, "keys/\(keyID)")), token: token)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ResetAPIKeyQuotaPayload())
        let _: APIEnvelope<IgnoredAPIData> = try await send(request)
    }

    private func fetchAccountMetrics(profile: StationProfile, token: String) async throws -> AccountMetrics {
        let request = authenticatedRequest(URLRequest(url: try endpoint(profile, "usage/dashboard/stats")), token: token)
        let envelope: APIEnvelope<DashboardStats> = try await send(request)
        return AccountMetrics(totalTokens: max(envelope.data.totalTokens, 0), totalActualCost: max(envelope.data.totalActualCost, 0))
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
        let request = authenticatedRequest(URLRequest(url: components.url!), token: token)
        let envelope: APIEnvelope<UsageRecordListData> = try await send(request)
        return envelope.data.items
    }

    private func fetchNewAPIStatus(profile: StationProfile) async throws -> NewAPIStatusData {
        let request = URLRequest(url: try endpoint(profile, "status"))
        let envelope: NewAPIEnvelope<NewAPIStatusData> = try await sendNewAPI(request)
        guard let data = envelope.data, data.quotaPerUnit > 0 else { throw APIClientError.invalidResponse }
        return data
    }

    private func fetchNewAPIUser(profile: StationProfile, authenticated: AuthenticatedSession) async throws -> NewAPIUserData {
        let request = authenticatedRequest(URLRequest(url: try endpoint(profile, "user/self")), authenticated: authenticated)
        let envelope: NewAPIEnvelope<NewAPIUserData> = try await sendNewAPI(request)
        guard let data = envelope.data else { throw APIClientError.invalidResponse }
        return data
    }

    private func fetchNewAPITokens(profile: StationProfile, authenticated: AuthenticatedSession) async throws -> [NewAPIToken] {
        var page = 1
        var total = Int.max
        var tokens: [NewAPIToken] = []
        while tokens.count < total {
            let tokenURL = try endpoint(profile, "token").appendingPathComponent("")
            var components = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "p", value: String(page)), URLQueryItem(name: "size", value: "100")]
            let request = authenticatedRequest(URLRequest(url: components.url!), authenticated: authenticated)
            let envelope: NewAPIEnvelope<NewAPITokenPageData> = try await sendNewAPI(request)
            guard let data = envelope.data else { throw APIClientError.invalidResponse }
            total = data.total
            tokens.append(contentsOf: data.items)
            if data.items.isEmpty || data.items.count < max(data.pageSize, 1) { break }
            page += 1
        }
        return tokens
    }

    private func fetchNewAPIData(profile: StationProfile, authenticated: AuthenticatedSession) async throws -> [NewAPIDataPoint] {
        let window = try unixDayWindow(timezone: profile.timezone)
        var components = URLComponents(url: try endpoint(profile, "data/self"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_timestamp", value: String(window.start)),
            URLQueryItem(name: "end_timestamp", value: String(window.end)),
            URLQueryItem(name: "default_time", value: "hour")
        ]
        let request = authenticatedRequest(URLRequest(url: components.url!), authenticated: authenticated)
        let envelope: NewAPIEnvelope<[NewAPIDataPoint]> = try await sendNewAPI(request)
        return envelope.data ?? []
    }

    private func fetchNewAPITodayUsage(
        profile: StationProfile,
        authenticated: AuthenticatedSession,
        keys: [UsageKey],
        quotaPerUnit: Double
    ) async throws -> [Int: Double] {
        guard !keys.isEmpty else { return [:] }
        let window = try unixDayWindow(timezone: profile.timezone)
        return try await withThrowingTaskGroup(of: (Int, Double).self, returning: [Int: Double].self) { group in
            for key in keys {
                group.addTask {
                    let stat = try await self.fetchNewAPILogStat(
                        profile: profile,
                        authenticated: authenticated,
                        tokenName: key.name,
                        window: window
                    )
                    return (key.id, max(stat.quota / max(quotaPerUnit, 1), 0))
                }
            }
            var result: [Int: Double] = [:]
            for try await (id, cost) in group { result[id] = cost }
            return result
        }
    }

    private func fetchNewAPILogStat(
        profile: StationProfile,
        authenticated: AuthenticatedSession,
        tokenName: String,
        window: UnixDateWindow
    ) async throws -> NewAPILogStatData {
        var components = URLComponents(url: try endpoint(profile, "log/self/stat"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "0"),
            URLQueryItem(name: "token_name", value: tokenName),
            URLQueryItem(name: "model_name", value: ""),
            URLQueryItem(name: "start_timestamp", value: String(window.start)),
            URLQueryItem(name: "end_timestamp", value: String(window.end)),
            URLQueryItem(name: "group", value: "")
        ]
        let request = authenticatedRequest(URLRequest(url: components.url!), authenticated: authenticated)
        let envelope: NewAPIEnvelope<NewAPILogStatData> = try await sendNewAPI(request)
        guard let data = envelope.data else { throw APIClientError.invalidResponse }
        return data
    }

    private func fetchNewAPIUsageHistory(
        profile: StationProfile,
        authenticated: AuthenticatedSession,
        quotaPerUnit: Double
    ) async throws -> [UsageRecord] {
        let window = try unixDayWindow(timezone: profile.timezone)
        var components = URLComponents(url: try endpoint(profile, "log/self"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "page_size", value: "50"),
            URLQueryItem(name: "type", value: "0"),
            URLQueryItem(name: "token_name", value: ""),
            URLQueryItem(name: "model_name", value: ""),
            URLQueryItem(name: "start_timestamp", value: String(window.start)),
            URLQueryItem(name: "end_timestamp", value: String(window.end)),
            URLQueryItem(name: "group", value: ""),
            URLQueryItem(name: "request_id", value: "")
        ]
        let request = authenticatedRequest(URLRequest(url: components.url!), authenticated: authenticated)
        let envelope: NewAPIEnvelope<NewAPILogPageData> = try await sendNewAPI(request)
        guard let data = envelope.data else { throw APIClientError.invalidResponse }
        return data.items.map { item in
            UsageRecord(
                id: item.id,
                apiKeyID: item.tokenID,
                apiKey: UsageRecordAPIKey(name: item.tokenName),
                model: item.modelName,
                reasoningEffort: reasoningEffort(from: item.other),
                actualCost: max(item.quota / max(quotaPerUnit, 1), 0),
                createdAt: Date(timeIntervalSince1970: TimeInterval(item.createdAt))
            )
        }
    }

    private func makeUsageKey(_ token: NewAPIToken, quotaPerUnit: Double) -> UsageKey {
        let used = max(token.usedQuota / max(quotaPerUnit, 1), 0)
        let total = token.unlimitedQuota ? 0 : max((token.remainQuota + token.usedQuota) / max(quotaPerUnit, 1), 0)
        let status = token.status == 1 ? "active" : "inactive"
        let timestamp = token.accessedTime ?? token.createdTime
        return UsageKey(
            id: token.id,
            name: token.name,
            status: status,
            quota: total,
            quotaUsed: used,
            updatedAt: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            group: token.group
        )
    }

    private func reasoningEffort(from other: String?) -> String? {
        guard let other, let data = other.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["reasoning_effort"] as? String
    }

    private func authenticatedRequest(_ request: URLRequest, token: String) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func authenticatedRequest(_ request: URLRequest, authenticated: AuthenticatedSession) -> URLRequest {
        var request = request
        if let token = authenticated.token, !token.isEmpty {
            request = authenticatedRequest(request, token: token)
        }
        if let userID = authenticated.userID { request.setValue(String(userID), forHTTPHeaderField: "New-API-User") }
        return request
    }

    private func bearerToken(_ authenticated: AuthenticatedSession) throws -> String {
        guard let token = authenticated.token, !token.isEmpty else { throw APIClientError.authenticationFailed }
        return token
    }

    private func clearCookies(for profile: StationProfile) {
        guard let url = URL(string: profile.serviceURL),
              let storage = session.configuration.httpCookieStorage,
              let cookies = storage.cookies(for: url) else { return }
        for cookie in cookies { storage.deleteCookie(cookie) }
    }

    private func endpoint(_ profile: StationProfile, _ path: String) throws -> URL {
        guard let baseURL = profile.apiBaseURL else { throw StationProfileError.invalidServiceURL }
        return baseURL.appending(path: path)
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<Value> {
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

    private func sendNewAPI<Value: Decodable>(_ request: URLRequest) async throws -> NewAPIEnvelope<Value> {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw APIClientError.httpStatus(response.statusCode) }
        do {
            let envelope = try JSONDecoder().decode(NewAPIEnvelope<Value>.self, from: data)
            guard envelope.success else {
                throw APIClientError.api(code: response.statusCode, message: envelope.message)
            }
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

private struct NewAPILoginPayload: Encodable, Sendable {
    let username: String
    let password: String
}

private struct ProbeEnvelope: Decodable {
    let code: Int
    let message: String
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

private struct UnixDateWindow: Sendable {
    let start: Int64
    let end: Int64
}

private func unixDayWindow(timezone: String, now: Date = Date()) throws -> UnixDateWindow {
    guard let timeZone = TimeZone(identifier: timezone) else { throw StationProfileError.invalidTimezone }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = calendar.startOfDay(for: now)
    return UnixDateWindow(start: Int64(start.timeIntervalSince1970), end: Int64(now.timeIntervalSince1970))
}

enum WeeklyResetCalculator {
    static let period: TimeInterval = 7 * 24 * 60 * 60

    static func nextReset(windowStart: Date?, expiresAt: Date?, now: Date = Date()) -> Date? {
        guard let windowStart else { return nil }
        let elapsed = max(now.timeIntervalSince(windowStart), 0)
        let completedPeriods = floor(elapsed / period)
        let candidate = windowStart.addingTimeInterval((completedPeriods + 1) * period)
        if let expiresAt, candidate >= expiresAt { return nil }
        return candidate
    }
}

enum DailyResetCalculator {
    static let period: TimeInterval = 24 * 60 * 60

    static func nextReset(windowStart: Date?, expiresAt: Date?, now: Date = Date()) -> Date? {
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
        guard let timeZone = TimeZone(identifier: timezone) else { throw StationProfileError.invalidTimezone }
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
