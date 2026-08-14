import Foundation

struct APIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: Value
}

struct LoginPayload: Encodable, Sendable {
    let email: String
    let password: String
}

struct LoginData: Decodable, Sendable {
    let accessToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let requires2FA: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case requires2FA = "requires_2fa"
    }
}

struct PublicSettingsData: Decodable, Sendable {
    let version: String?
    let siteName: String?
    let serverTimezone: String?

    enum CodingKeys: String, CodingKey {
        case version
        case siteName = "site_name"
        case serverTimezone = "server_timezone"
    }

    var hasSub2APIFingerprint: Bool {
        [version, siteName, serverTimezone].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
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

struct SubscriptionGroup: Decodable, Sendable {
    let weeklyLimitUSD: Double?

    enum CodingKeys: String, CodingKey {
        case weeklyLimitUSD = "weekly_limit_usd"
    }
}

struct SubscriptionRecord: Decodable, Sendable {
    let id: Int?
    let status: String
    let name: String?
    let weeklyUsageUSD: Double?
    let directWeeklyLimitUSD: Double?
    let weeklyWindowStart: Date?
    let expiresAt: Date?
    let group: SubscriptionGroup?

    enum CodingKeys: String, CodingKey {
        case id, status, group, name
        case weeklyUsageUSD = "weekly_usage_usd"
        case directWeeklyLimitUSD = "weekly_limit_usd"
        case weeklyWindowStart = "weekly_window_start"
        case expiresAt = "expires_at"
    }

    var weeklyLimitUSD: Double? { directWeeklyLimitUSD ?? group?.weeklyLimitUSD }
}

struct WeeklyUsage: Equatable, Sendable {
    let subscriptionID: Int?
    let used: Double
    let total: Double
    let resetAt: Date?

    init(subscriptionID: Int? = nil, used: Double, total: Double, resetAt: Date? = nil) {
        self.subscriptionID = subscriptionID
        self.used = used
        self.total = total
        self.resetAt = resetAt
    }
}

struct AccountMetrics: Equatable, Sendable {
    let totalTokens: Int64
    let totalActualCost: Double
}

struct UsageData: Equatable, Sendable {
    let weeklyUsage: WeeklyUsage?
    let accountMetrics: AccountMetrics?
    let keys: [UsageKey]
    let usageRecords: [UsageRecord]?
    let subscriptionOptions: [SubscriptionOption]?
    let capabilities: Set<StationCapability>

    init(
        weeklyUsage: WeeklyUsage?,
        accountMetrics: AccountMetrics?,
        keys: [UsageKey],
        usageRecords: [UsageRecord]?,
        subscriptionOptions: [SubscriptionOption]? = nil,
        capabilities: Set<StationCapability>
    ) {
        self.weeklyUsage = weeklyUsage
        self.accountMetrics = accountMetrics
        self.keys = keys
        self.usageRecords = usageRecords
        self.subscriptionOptions = subscriptionOptions
        self.capabilities = capabilities
    }
}

struct UsageKey: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let quota: Double
    let quotaUsed: Double
    let updatedAt: Date?
    var currentConcurrency: Int? = nil
    var todayActualCost: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, status, quota
        case quotaUsed = "quota_used"
        case updatedAt = "updated_at"
        case currentConcurrency = "current_concurrency"
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

struct UsageSnapshot: Equatable, Sendable {
    static let maximumUsageRecords = 50

    let keys: [UsageKey]
    let usageRecords: [UsageRecord]?
    let weeklyUsage: WeeklyUsage?
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
            case .twoFactorAuthenticationRequired:
                return DashboardIssue(kind: .authentication, message: apiError.localizedDescription)
            case .backendModeRestricted, .loginRejected:
                return DashboardIssue(kind: .authentication, message: apiError.localizedDescription)
            case .interactiveAuthenticationRequired, .stationProbeRejected:
                return stationIssue(apiError.localizedDescription)
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

    private static func authenticationMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("invalid credential")
            || value.contains("invalid email or password")
            || value.contains("user is not active")
            || value.contains("token expired")
            || value.contains("token revoked")
    }
}

enum UsagePhase: Equatable, Sendable {
    case needsConfiguration
    case loading
    case ready
    case failed(DashboardIssue)
}
