import Foundation

enum APIClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case api(code: Int, message: String)
    case missingSubscription

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .httpStatus(let status):
            return "服务器请求失败（HTTP \(status)）"
        case .api(_, let message):
            return message
        case .missingSubscription:
            return "没有找到可用的订阅周额度"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetchUsage(credentials: Credentials) async throws -> UsageData
}

actor APIClient: UsageFetching {
    private let session: URLSession
    private let baseURL = URL(string: "https://sub2apis.ruobin.dev")!
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var tokenCredentials: Credentials?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(credentials: Credentials) async throws -> UsageData {
        let token = try await validToken(credentials: credentials)
        do {
            return try await fetchUsage(token: token)
        } catch APIClientError.httpStatus(401), APIClientError.httpStatus(403) {
            invalidateToken()
            let refreshedToken = try await validToken(credentials: credentials)
            return try await fetchUsage(token: refreshedToken)
        }
    }

    private func fetchUsage(token: String) async throws -> UsageData {
        async let weeklyUsage = fetchWeeklyUsage(token: token)
        async let keys = fetchAllKeys(token: token)
        return try await UsageData(weeklyUsage: weeklyUsage, keys: keys)
    }

    private func validToken(credentials: Credentials) async throws -> String {
        let hasTimeRemaining = tokenExpiresAt.map { $0 > Date().addingTimeInterval(30) } ?? true
        if let cachedToken, tokenCredentials == credentials, hasTimeRemaining {
            return cachedToken
        }

        let loginData = try await login(credentials: credentials)
        cachedToken = loginData.accessToken
        tokenCredentials = credentials
        tokenExpiresAt = loginData.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return loginData.accessToken
    }

    private func invalidateToken() {
        cachedToken = nil
        tokenExpiresAt = nil
        tokenCredentials = nil
    }

    private func login(credentials: Credentials) async throws -> LoginData {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LoginPayload(email: credentials.email, password: credentials.password)
        )

        let envelope: APIEnvelope<LoginData> = try await send(request)
        return envelope.data
    }

    private func fetchAllKeys(token: String) async throws -> [UsageKey] {
        let requestedPageSize = 100
        var page = 1
        var receivedCount = 0
        var orderedKeys: [UsageKey] = []
        var keyIndexes: [Int: Int] = [:]

        while true {
            let data = try await fetchKeyPage(
                token: token,
                page: page,
                pageSize: requestedPageSize
            )
            receivedCount += data.items.count

            for key in data.items {
                if let index = keyIndexes[key.id] {
                    orderedKeys[index] = key
                } else {
                    keyIndexes[key.id] = orderedKeys.count
                    orderedKeys.append(key)
                }
            }

            if let pages = data.pages {
                if page >= pages { break }
            } else if receivedCount >= data.total || data.items.isEmpty {
                break
            } else {
                let effectivePageSize = max(data.pageSize ?? requestedPageSize, 1)
                if data.items.count < effectivePageSize { break }
            }
            page += 1
        }

        return orderedKeys
    }

    private func fetchWeeklyUsage(token: String) async throws -> WeeklyUsage {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/v1/subscriptions"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "timezone", value: "Asia/Shanghai")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let envelope: APIEnvelope<[SubscriptionRecord]> = try await send(request)
        let active = envelope.data.filter { $0.status == "active" }
        let subscription = active.first(where: { $0.weeklyLimitUSD != nil })
            ?? active.first
            ?? envelope.data.first(where: { $0.weeklyLimitUSD != nil })
            ?? envelope.data.first
        guard let subscription, let total = subscription.weeklyLimitUSD else {
            throw APIClientError.missingSubscription
        }
        return WeeklyUsage(
            used: max(subscription.weeklyUsageUSD ?? 0, 0),
            total: max(total, 0)
        )
    }

    private func fetchKeyPage(token: String, page: Int, pageSize: Int) async throws -> KeyListData {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/v1/keys"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: "created_at"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "timezone", value: "Asia/Shanghai")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let envelope: APIEnvelope<KeyListData> = try await send(request)
        return envelope.data
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<Value> {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw APIClientError.httpStatus(response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let envelope = try decoder.decode(APIEnvelope<Value>.self, from: data)
        guard envelope.code == 0 else {
            throw APIClientError.api(code: envelope.code, message: envelope.message)
        }
        return envelope
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: try decoder.singleValueContainer(),
            debugDescription: "Invalid ISO-8601 date: \(value)"
        )
    }
}
