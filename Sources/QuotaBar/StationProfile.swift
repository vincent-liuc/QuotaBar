import Foundation

enum StationCapability: String, Codable, CaseIterable, Sendable {
    case subscriptions
    case accountMetrics
    case apiKeyDailyUsage
    case concurrency
    case usageHistory
}

enum SubscriptionSelection: Codable, Equatable, Sendable {
    case automatic
    case manual(Int)

    private enum CodingKeys: String, CodingKey { case mode, id }
    private enum Mode: String, Codable { case automatic, manual }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .automatic:
            self = .automatic
        case .manual:
            self = .manual(try container.decode(Int.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Mode.automatic, forKey: .mode)
        case .manual(let id):
            try container.encode(Mode.manual, forKey: .mode)
            try container.encode(id, forKey: .id)
        }
    }
}

struct StationProfile: Codable, Equatable, Identifiable, Sendable {
    static let defaultServiceURL = "https://sub2apis.ruobin.dev"
    static let defaultAPIPath = "/api/v1"

    let id: UUID
    var name: String
    var serviceURL: String
    var apiPath: String
    var timezone: String
    var subscriptionSelection: SubscriptionSelection
    var automaticallyResetsAPIKeyQuota: Bool
    var capabilities: Set<StationCapability>
    var lastCheckedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, serviceURL, apiPath, timezone, subscriptionSelection
        case automaticallyResetsAPIKeyQuota, capabilities, lastCheckedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        serviceURL: String,
        apiPath: String = Self.defaultAPIPath,
        timezone: String = TimeZone.current.identifier,
        subscriptionSelection: SubscriptionSelection = .automatic,
        automaticallyResetsAPIKeyQuota: Bool = false,
        capabilities: Set<StationCapability> = [],
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.serviceURL = serviceURL
        self.apiPath = apiPath
        self.timezone = timezone
        self.subscriptionSelection = subscriptionSelection
        self.automaticallyResetsAPIKeyQuota = automaticallyResetsAPIKeyQuota
        self.capabilities = capabilities
        self.lastCheckedAt = lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        serviceURL = try container.decode(String.self, forKey: .serviceURL)
        apiPath = try container.decode(String.self, forKey: .apiPath)
        timezone = try container.decode(String.self, forKey: .timezone)
        subscriptionSelection = try container.decode(SubscriptionSelection.self, forKey: .subscriptionSelection)
        automaticallyResetsAPIKeyQuota = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyResetsAPIKeyQuota
        ) ?? false
        capabilities = try container.decodeIfPresent(Set<StationCapability>.self, forKey: .capabilities) ?? []
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    static func legacyDefault() -> StationProfile {
        StationProfile(
            name: "当前站点",
            serviceURL: defaultServiceURL,
            timezone: "Asia/Shanghai"
        )
    }

    func validated() throws -> StationProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw StationProfileError.emptyName }
        let endpoint = try StationEndpoint(serviceURL: serviceURL, apiPath: apiPath)
        let normalizedTimezone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TimeZone(identifier: normalizedTimezone) != nil else {
            throw StationProfileError.invalidTimezone
        }
        var result = self
        result.name = normalizedName
        result.serviceURL = endpoint.serviceURL.absoluteString
        result.apiPath = endpoint.apiPath
        result.timezone = normalizedTimezone
        return result
    }

    var apiBaseURL: URL? {
        try? StationEndpoint(serviceURL: serviceURL, apiPath: apiPath).apiBaseURL
    }
}

struct StationEndpoint: Equatable, Sendable {
    let serviceURL: URL
    let apiPath: String
    let apiBaseURL: URL

    init(serviceURL rawServiceURL: String, apiPath rawAPIPath: String) throws {
        let trimmed = rawServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw StationProfileError.invalidServiceURL
        }

        components.scheme = "https"
        var prefix = components.percentEncodedPath
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix
        guard let normalizedServiceURL = components.url else {
            throw StationProfileError.invalidServiceURL
        }

        var path = rawAPIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = StationProfile.defaultAPIPath }
        guard !path.contains("?") && !path.contains("#") else {
            throw StationProfileError.invalidAPIPath
        }
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        guard var apiComponents = URLComponents(url: normalizedServiceURL, resolvingAgainstBaseURL: false) else {
            throw StationProfileError.invalidServiceURL
        }
        let servicePrefix = apiComponents.percentEncodedPath == "/" ? "" : apiComponents.percentEncodedPath
        apiComponents.percentEncodedPath = servicePrefix + path
        guard let base = apiComponents.url else { throw StationProfileError.invalidAPIPath }

        serviceURL = normalizedServiceURL
        apiPath = path
        apiBaseURL = base
    }
}

enum StationProfileError: LocalizedError, Equatable {
    case emptyName
    case invalidServiceURL
    case invalidAPIPath
    case invalidTimezone
    case noActiveStation
    case missingCredentials
    case cannotDeleteOnlyStation

    var errorDescription: String? {
        switch self {
        case .emptyName: return "站点名称不能为空"
        case .invalidServiceURL: return "服务地址必须是有效的 HTTPS 地址"
        case .invalidAPIPath: return "API 路径格式不正确"
        case .invalidTimezone: return "时区格式不正确"
        case .noActiveStation: return "请先添加一个站点"
        case .missingCredentials: return "请填写当前站点的登录账号和密码"
        case .cannotDeleteOnlyStation: return "至少需要保留一个站点"
        }
    }
}

struct StationProfilesState: Codable, Equatable, Sendable {
    var profiles: [StationProfile]
    var activeProfileID: UUID?
}

final class StationProfileStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let stateKey = "stationProfiles.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StationProfilesState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(StationProfilesState.self, from: data) else {
            return StationProfilesState(profiles: [], activeProfileID: nil)
        }
        let activeID = state.profiles.contains(where: { $0.id == state.activeProfileID })
            ? state.activeProfileID
            : state.profiles.first?.id
        return StationProfilesState(profiles: state.profiles, activeProfileID: activeID)
    }

    func save(_ state: StationProfilesState) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: stateKey)
    }
}

struct SubscriptionOption: Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let hasWeeklyLimit: Bool
}

struct ConnectionTestResult: Equatable, Sendable {
    let capabilities: Set<StationCapability>
    let subscriptions: [SubscriptionOption]
    let checkedAt: Date
}
