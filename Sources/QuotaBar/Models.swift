import Foundation

struct APIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: Value
}

struct NewAPIEnvelope<Value: Decodable>: Decodable {
    let success: Bool
    let message: String
    let data: Value?
}

struct NewAPILoginData: Decodable, Sendable {
    let id: Int
    let token: String?
    let require2FA: Bool?

    enum CodingKeys: String, CodingKey {
        case id, token
        case require2FA = "require_2fa"
    }
}

struct NewAPIStatusData: Decodable, Sendable {
    let quotaPerUnit: Double
    let turnstileCheck: Bool
    let displayInCurrency: Bool
    let quotaDisplayType: String?
    let usdExchangeRate: Double?

    enum CodingKeys: String, CodingKey {
        case quotaPerUnit = "quota_per_unit"
        case turnstileCheck = "turnstile_check"
        case displayInCurrency = "display_in_currency"
        case quotaDisplayType = "quota_display_type"
        case usdExchangeRate = "usd_exchange_rate"
    }
}

struct NewAPIUserData: Decodable, Sendable {
    let id: Int
    let quota: Double
    let usedQuota: Double
    let requestCount: Int

    enum CodingKeys: String, CodingKey {
        case id, quota
        case usedQuota = "used_quota"
        case requestCount = "request_count"
    }
}

struct NewAPITokenPageData: Decodable, Sendable {
    let page: Int
    let pageSize: Int
    let total: Int
    let items: [NewAPIToken]

    enum CodingKeys: String, CodingKey {
        case page, total, items
        case pageSize = "page_size"
    }
}

struct NewAPIToken: Decodable, Sendable {
    let id: Int
    let status: Int
    let name: String
    let createdTime: Int64?
    let accessedTime: Int64?
    let expiredTime: Int64?
    let remainQuota: Double
    let unlimitedQuota: Bool
    let usedQuota: Double
    let group: String?

    enum CodingKeys: String, CodingKey {
        case id, status, name, group
        case createdTime = "created_time"
        case accessedTime = "accessed_time"
        case expiredTime = "expired_time"
        case remainQuota = "remain_quota"
        case unlimitedQuota = "unlimited_quota"
        case usedQuota = "used_quota"
    }
}

struct NewAPIDataPoint: Decodable, Sendable {
    let tokenUsed: Int64

    enum CodingKeys: String, CodingKey {
        case tokenUsed = "token_used"
    }
}

struct NewAPILogPageData: Decodable, Sendable {
    let page: Int
    let pageSize: Int
    let total: Int
    let items: [NewAPILogItem]

    enum CodingKeys: String, CodingKey {
        case page, total, items
        case pageSize = "page_size"
    }
}

struct NewAPILogItem: Decodable, Sendable {
    let id: Int
    let createdAt: Int64
    let tokenName: String
    let modelName: String
    let quota: Double
    let tokenID: Int?
    let other: String?

    enum CodingKeys: String, CodingKey {
        case id, quota, other
        case createdAt = "created_at"
        case tokenName = "token_name"
        case modelName = "model_name"
        case tokenID = "token_id"
    }
}

struct NewAPILogStatData: Decodable, Sendable {
    let quota: Double
    let rpm: Double
    let tpm: Double
}

struct LoginPayload: Encodable, Sendable {
    let email: String
    let password: String
}

struct LoginData: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct KeyListData: Decodable, Sendable {
    let items: [UsageKey]
    let total: Int
    let page: Int?
    let pageSize: Int?
    let pages: Int?

    enum CodingKeys: String, CodingKey {
        case items, total, page, pages
        case pageSize = "page_size"
    }
}

struct UsageRecordListData: Decodable, Sendable {
    let items: [UsageRecord]
    let total: Int
    let page: Int?
    let pageSize: Int?
    let pages: Int?

    enum CodingKeys: String, CodingKey {
        case items, total, page, pages
        case pageSize = "page_size"
    }
}

struct UsageRecordAPIKey: Decodable, Equatable, Sendable {
    let name: String
}

struct UsageRecord: Decodable, Equatable, Sendable {
    let id: Int?
    let apiKeyID: Int?
    let apiKey: UsageRecordAPIKey?
    let model: String
    let reasoningEffort: String?
    let actualCost: Double
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, model
        case apiKeyID = "api_key_id"
        case apiKey = "api_key"
        case reasoningEffort = "reasoning_effort"
        case actualCost = "actual_cost"
        case createdAt = "created_at"
    }

    var apiKeyName: String {
        let name = apiKey?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        if let apiKeyID { return "API Key #\(apiKeyID)" }
        return "已删除的 API Key"
    }
}

struct APIKeyUsagePayload: Codable, Sendable {
    let apiKeyIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case apiKeyIDs = "api_key_ids"
    }
}

struct ResetAPIKeyQuotaPayload: Encodable, Sendable {
    let resetQuota = true

    enum CodingKeys: String, CodingKey {
        case resetQuota = "reset_quota"
    }
}

struct IgnoredAPIData: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

struct APIKeyUsageData: Decodable, Sendable {
    let stats: [String: APIKeyUsageStat]
}

struct APIKeyUsageStat: Decodable, Sendable {
    let apiKeyID: Int
    let todayActualCost: Double

    enum CodingKeys: String, CodingKey {
        case apiKeyID = "api_key_id"
        case todayActualCost = "today_actual_cost"
    }
}

struct DashboardStats: Decodable, Sendable {
    let totalTokens: Int64
    let totalActualCost: Double

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case totalActualCost = "total_actual_cost"
    }
}

struct DashboardModelUsageData: Decodable, Sendable {
    let models: [DashboardModelUsage]
}

struct DashboardModelUsage: Decodable, Sendable {
    let model: String
    let requests: Int
}

struct SubscriptionGroup: Decodable, Sendable {
    let weeklyLimitUSD: Double?
    let dailyLimitUSD: Double?

    enum CodingKeys: String, CodingKey {
        case weeklyLimitUSD = "weekly_limit_usd"
        case dailyLimitUSD = "daily_limit_usd"
    }
}

struct SubscriptionRecord: Decodable, Sendable {
    let id: Int?
    let status: String
    let name: String?
    let weeklyUsageUSD: Double?
    let directWeeklyLimitUSD: Double?
    let dailyUsageUSD: Double?
    let directDailyLimitUSD: Double?
    let dailyWindowStart: Date?
    let weeklyWindowStart: Date?
    let expiresAt: Date?
    let group: SubscriptionGroup?

    enum CodingKeys: String, CodingKey {
        case id, status, group, name
        case weeklyUsageUSD = "weekly_usage_usd"
        case directWeeklyLimitUSD = "weekly_limit_usd"
        case dailyUsageUSD = "daily_usage_usd"
        case directDailyLimitUSD = "daily_limit_usd"
        case dailyWindowStart = "daily_window_start"
        case weeklyWindowStart = "weekly_window_start"
        case expiresAt = "expires_at"
    }

    var weeklyLimitUSD: Double? { directWeeklyLimitUSD ?? group?.weeklyLimitUSD }
    var dailyLimitUSD: Double? { directDailyLimitUSD ?? group?.dailyLimitUSD }
}

struct WeeklyUsage: Equatable, Sendable {
    let kind: QuotaUsageKind
    let subscriptionID: Int?
    let used: Double
    let total: Double
    let resetAt: Date?

    init(
        kind: QuotaUsageKind = .weekly,
        subscriptionID: Int? = nil,
        used: Double,
        total: Double,
        resetAt: Date? = nil
    ) {
        self.kind = kind
        self.subscriptionID = subscriptionID
        self.used = used
        self.total = total
        self.resetAt = resetAt
    }
}

struct DailyUsage: Equatable, Sendable {
    let subscriptionID: Int?
    let subscriptionName: String?
    let used: Double
    let total: Double
    let resetAt: Date?

    init(
        subscriptionID: Int? = nil,
        subscriptionName: String? = nil,
        used: Double,
        total: Double,
        resetAt: Date? = nil
    ) {
        self.subscriptionID = subscriptionID
        self.subscriptionName = subscriptionName
        self.used = used
        self.total = total
        self.resetAt = resetAt
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(used / total, 0), 1)
    }
}

enum QuotaUsageKind: String, Equatable, Sendable {
    case weekly
    case tokenPool
    case accountPool
}

struct AccountMetrics: Equatable, Sendable {
    let totalTokens: Int64
    let totalActualCost: Double
    let balance: Double?
    let requestCount: Int?
    let image2RequestCount: Int?
    let tokensPeriod: MetricTokensPeriod

    init(
        totalTokens: Int64,
        totalActualCost: Double,
        balance: Double? = nil,
        requestCount: Int? = nil,
        image2RequestCount: Int? = nil,
        tokensPeriod: MetricTokensPeriod = .lifetime
    ) {
        self.totalTokens = totalTokens
        self.totalActualCost = totalActualCost
        self.balance = balance
        self.requestCount = requestCount
        self.image2RequestCount = image2RequestCount
        self.tokensPeriod = tokensPeriod
    }
}

enum MetricTokensPeriod: String, Equatable, Sendable {
    case lifetime
    case today
}

struct UsageData: Equatable, Sendable {
    let weeklyUsage: WeeklyUsage?
    let dailyUsage: DailyUsage?
    let accountMetrics: AccountMetrics?
    let keys: [UsageKey]
    let usageRecords: [UsageRecord]?
    let capabilities: Set<StationCapability>
}

struct UsageKey: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let quota: Double
    let quotaUsed: Double
    let updatedAt: Date?
    var group: String? = nil
    var currentConcurrency: Int? = nil
    var todayActualCost: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, status, quota, group
        case quotaUsed = "quota_used"
        case updatedAt = "updated_at"
        case currentConcurrency = "current_concurrency"
    }

    init(
        id: Int,
        name: String,
        status: String,
        quota: Double,
        quotaUsed: Double,
        updatedAt: Date?,
        group: String? = nil,
        currentConcurrency: Int? = nil,
        todayActualCost: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.quota = quota
        self.quotaUsed = quotaUsed
        self.updatedAt = updatedAt
        self.group = group
        self.currentConcurrency = currentConcurrency
        self.todayActualCost = todayActualCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        quota = try container.decode(Double.self, forKey: .quota)
        quotaUsed = try container.decode(Double.self, forKey: .quotaUsed)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        currentConcurrency = try container.decodeIfPresent(Int.self, forKey: .currentConcurrency)
        todayActualCost = nil

        // Sub2API returns a group object while New API uses a group string.
        // Keep the shared view model tolerant of both response shapes.
        if let value = try? container.decode(String.self, forKey: .group) {
            group = value
        } else if let value = try? container.decode(UsageKeyGroup.self, forKey: .group) {
            group = value.name
        } else {
            group = nil
        }
    }

    var remaining: Double { max(quota - quotaUsed, 0) }

    var progress: Double {
        guard quota > 0 else { return 0 }
        return min(max(quotaUsed / quota, 0), 1)
    }

    var isVisible: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "inactive"
    }
    var concurrency: Int { max(currentConcurrency ?? 0, 0) }
}

private struct UsageKeyGroup: Decodable {
    let name: String?
}

struct UsageSnapshot: Equatable, Sendable {
    static let maximumUsageRecords = 50

    let keys: [UsageKey]
    let usageRecords: [UsageRecord]?
    let weeklyUsage: WeeklyUsage?
    let dailyUsage: DailyUsage?
    let used: Double
    let total: Double
    let accountMetrics: AccountMetrics?
    let fetchedAt: Date

    var serverUpdatedAt: Date? { keys.compactMap(\.updatedAt).max() }

    var remaining: Double { max(total - used, 0) }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(used / total, 0), 1)
    }

    var isOverQuota: Bool { total > 0 && used > total }

    init(
        weeklyUsage: WeeklyUsage?,
        dailyUsage: DailyUsage? = nil,
        accountMetrics: AccountMetrics? = nil,
        keys: [UsageKey],
        usageRecords: [UsageRecord]? = nil,
        fetchedAt: Date = Date()
    ) {
        self.keys = keys.filter(\.isVisible).sorted { lhs, rhs in
            if (lhs.todayActualCost ?? -1) != (rhs.todayActualCost ?? -1) {
                return (lhs.todayActualCost ?? -1) > (rhs.todayActualCost ?? -1)
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.weeklyUsage = weeklyUsage
        self.dailyUsage = dailyUsage
        self.usageRecords = usageRecords.map { Array($0.prefix(Self.maximumUsageRecords)) }
        used = weeklyUsage?.used ?? 0
        total = weeklyUsage?.total ?? 0
        self.accountMetrics = accountMetrics
        self.fetchedAt = fetchedAt
    }

    var hasWeeklyUsage: Bool { weeklyUsage != nil }
}

struct Credentials: Equatable, Sendable {
    let email: String
    let password: String
}

enum SettingsTab: Int, CaseIterable, Sendable {
    case general
    case station
    case account
    case display
    case update
}

struct ConfigurationProgress: Equatable, Sendable {
    let stationIsValid: Bool
    let accountIsValid: Bool

    var isComplete: Bool { stationIsValid && accountIsValid }
}

struct DashboardIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case authentication
        case station
        case temporary
        case unknown
    }

    let kind: Kind
    let message: String

    var settingsTab: SettingsTab? {
        switch kind {
        case .authentication: return .account
        case .station: return .station
        case .temporary, .unknown: return nil
        }
    }

    static func classify(_ error: Error) -> DashboardIssue {
        if let stationError = error as? StationProfileError {
            if stationError == .missingCredentials { return authenticationIssue }
            return DashboardIssue(kind: .station, message: stationError.localizedDescription)
        }
        if let apiError = error as? APIClientError {
            switch apiError {
            case .httpStatus(401), .httpStatus(403), .authenticationFailed:
                return authenticationIssue
            case .twoFactorAuthenticationRequired, .turnstileRequired:
                return DashboardIssue(kind: .authentication, message: apiError.localizedDescription)
            case .httpStatus(404), .httpStatus(405), .httpStatus(410),
                 .invalidResponse, .incompatibleStation:
                return stationIssue("站点信息有误或接口不兼容，请检查站点配置")
            case .httpStatus(408), .httpStatus(429):
                return temporaryIssue
            case .httpStatus(let status) where status >= 500:
                return temporaryIssue
            case .api(let code, let message):
                if code == 401 || code == 403 || authenticationMessage(message) {
                    return authenticationIssue
                }
                if code == 404 || code == 405 {
                    return stationIssue("站点信息有误或接口不兼容，请检查站点配置")
                }
                if code == 408 || code == 429 || code >= 500 { return temporaryIssue }
                return DashboardIssue(kind: .unknown, message: message)
            case .missingSubscription:
                return stationIssue(apiError.localizedDescription)
            case .httpStatus:
                return DashboardIssue(kind: .unknown, message: apiError.localizedDescription)
            }
        }

        if error is DecodingError {
            return stationIssue("站点信息有误或接口不兼容，请检查站点配置")
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .badURL, .unsupportedURL, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return stationIssue("无法连接当前站点，请检查站点地址和网络环境")
            default:
                return temporaryIssue
            }
        }
        return DashboardIssue(kind: .unknown, message: error.localizedDescription)
    }

    private static let authenticationIssue = DashboardIssue(
        kind: .authentication,
        message: "登录信息有误，请调整后再试"
    )
    private static let temporaryIssue = DashboardIssue(
        kind: .temporary,
        message: "服务暂时不可用，请稍后重试"
    )

    private static func stationIssue(_ message: String) -> DashboardIssue {
        DashboardIssue(kind: .station, message: message)
    }

    static func authenticationMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("invalid credential")
            || value.contains("invalid email or password")
            || value.contains("user is not active")
            || value.contains("token expired")
            || value.contains("token revoked")
            || value.contains("invalid username or password")
            || value.contains("用户名或密码")
            || value.contains("密码错误")
    }
}

enum UsagePhase: Equatable, Sendable {
    case needsConfiguration
    case loading
    case ready
    case failed(DashboardIssue)
}
