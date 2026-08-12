import Foundation

enum APIClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case api(code: Int, message: String)
    case missingSubscription
    case incompatibleStation

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case .httpStatus(let status): return "服务器请求失败（HTTP \(status)）"
        case .api(_, let message): return message
        case .missingSubscription: return "没有找到可用的订阅周额度"
        case .incompatibleStation: return "该地址不是可识别的 Sub2API 兼容站点"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData
    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult
    func invalidateSession() async
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

    func testConnection(profile: StationProfile, credentials: Credentials) async throws -> ConnectionTestResult {
        let profile = try profile.validated()
        let token = try await login(profile: profile, credentials: credentials).accessToken
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
    }

    func invalidateSession() {
        invalidateToken()
    }

    private func fetchUsage(profile: StationProfile, token: String) async throws -> UsageData {
        let keys = try await fetchAllKeys(profile: profile, token: token).filter(\.isActive)
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
        return WeeklyUsage(used: max(subscription.weeklyUsageUSD ?? 0, 0), total: max(total, 0))
    }

    private func validToken(profile: StationProfile, credentials: Credentials) async throws -> String {
        let identity = TokenIdentity(profile: profile, credentials: credentials)
        let hasTimeRemaining = tokenExpiresAt.map { $0 > Date().addingTimeInterval(30) } ?? true
        if let cachedToken, tokenIdentity == identity, hasTimeRemaining { return cachedToken }

        let loginData = try await login(profile: profile, credentials: credentials)
        cachedToken = loginData.accessToken
        tokenIdentity = identity
        tokenExpiresAt = loginData.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return loginData.accessToken
    }

    private func invalidateToken() {
        cachedToken = nil
        tokenExpiresAt = nil
        tokenIdentity = nil
    }

    private func login(profile: StationProfile, credentials: Credentials) async throws -> LoginData {
        var request = URLRequest(url: try endpoint(profile, "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginPayload(email: credentials.email, password: credentials.password))
        let envelope: APIEnvelope<LoginData> = try await send(request)
        return envelope.data
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
