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

struct APIKeyUsagePayload: Codable, Sendable {
    let apiKeyIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case apiKeyIDs = "api_key_ids"
    }
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
    let group: SubscriptionGroup?

    enum CodingKeys: String, CodingKey {
        case id, status, group, name
        case weeklyUsageUSD = "weekly_usage_usd"
        case directWeeklyLimitUSD = "weekly_limit_usd"
    }

    var weeklyLimitUSD: Double? { directWeeklyLimitUSD ?? group?.weeklyLimitUSD }
}

struct WeeklyUsage: Equatable, Sendable {
    let used: Double
    let total: Double
}

struct AccountMetrics: Equatable, Sendable {
    let totalTokens: Int64
    let totalActualCost: Double
}

struct UsageData: Equatable, Sendable {
    let weeklyUsage: WeeklyUsage?
    let accountMetrics: AccountMetrics?
    let keys: [UsageKey]
    let capabilities: Set<StationCapability>
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

    var isActive: Bool { status == "active" }
    var concurrency: Int { max(currentConcurrency ?? 0, 0) }
}

struct UsageSnapshot: Equatable, Sendable {
    let keys: [UsageKey]
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
        fetchedAt: Date = Date()
    ) {
        self.keys = keys.filter(\.isActive).sorted { lhs, rhs in
            if (lhs.todayActualCost ?? -1) != (rhs.todayActualCost ?? -1) {
                return (lhs.todayActualCost ?? -1) > (rhs.todayActualCost ?? -1)
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.weeklyUsage = weeklyUsage
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

enum UsagePhase: Equatable, Sendable {
    case needsConfiguration
    case loading
    case ready
    case failed(String)
}
