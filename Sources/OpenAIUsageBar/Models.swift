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

struct SubscriptionGroup: Decodable, Sendable {
    let weeklyLimitUSD: Double?

    enum CodingKeys: String, CodingKey {
        case weeklyLimitUSD = "weekly_limit_usd"
    }
}

struct SubscriptionRecord: Decodable, Sendable {
    let status: String
    let weeklyUsageUSD: Double?
    let directWeeklyLimitUSD: Double?
    let group: SubscriptionGroup?

    enum CodingKeys: String, CodingKey {
        case status, group
        case weeklyUsageUSD = "weekly_usage_usd"
        case directWeeklyLimitUSD = "weekly_limit_usd"
    }

    var weeklyLimitUSD: Double? { directWeeklyLimitUSD ?? group?.weeklyLimitUSD }
}

struct WeeklyUsage: Equatable, Sendable {
    let used: Double
    let total: Double
}

struct UsageData: Equatable, Sendable {
    let weeklyUsage: WeeklyUsage
    let keys: [UsageKey]
}

struct UsageKey: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let quota: Double
    let quotaUsed: Double
    let updatedAt: Date?
    var todayActualCost: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, name, status, quota
        case quotaUsed = "quota_used"
        case updatedAt = "updated_at"
    }

    var remaining: Double { max(quota - quotaUsed, 0) }

    var progress: Double {
        guard quota > 0 else { return 0 }
        return min(max(quotaUsed / quota, 0), 1)
    }

    var isActive: Bool { status == "active" }
}

struct UsageSnapshot: Equatable, Sendable {
    let keys: [UsageKey]
    let used: Double
    let total: Double
    let fetchedAt: Date

    var serverUpdatedAt: Date? { keys.compactMap(\.updatedAt).max() }

    var remaining: Double { max(total - used, 0) }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(used / total, 0), 1)
    }

    var isOverQuota: Bool { total > 0 && used > total }

    init(weeklyUsage: WeeklyUsage, keys: [UsageKey], fetchedAt: Date = Date()) {
        self.keys = keys.filter(\.isActive).sorted { lhs, rhs in
            if lhs.todayActualCost != rhs.todayActualCost {
                return lhs.todayActualCost > rhs.todayActualCost
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        used = weeklyUsage.used
        total = weeklyUsage.total
        self.fetchedAt = fetchedAt
    }
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
