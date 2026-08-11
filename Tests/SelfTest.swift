import Foundation

@main
enum SelfTest {
    static func main() async throws {
        try testDecodesUsageResponse()
        testWeeklyUsageAndProgress()
        testPreferenceNormalization()
        try await testPaginationAndDeduplication()
        print("Self-test passed: 4 checks")
    }

    private static func testDecodesUsageResponse() throws {
        let json = #"""
        {
          "code": 0,
          "message": "success",
          "data": {
            "items": [{
              "id": 104,
              "name": "Test OpenAI",
              "status": "active",
              "quota": 400,
              "quota_used": 22.3713036,
              "updated_at": "2026-08-11T10:31:58.067319+08:00"
            }],
            "total": 1,
            "page": 1,
            "page_size": 100,
            "pages": 1
          }
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let result = try decoder.decode(APIEnvelope<KeyListData>.self, from: Data(json.utf8))

        require(result.code == 0, "response code")
        require(result.data.items.first?.quota == 400, "quota")
        require(result.data.items.first?.quotaUsed == 22.3713036, "quota_used")
        require(result.data.items.first?.updatedAt != nil, "updated_at")
        require(result.data.page == 1, "page")
        require(result.data.pageSize == 100, "page_size")
        require(result.data.pages == 1, "pages")
        require(result.data.items.first?.todayActualCost == 0, "today cost defaults to zero")
    }

    private static func testWeeklyUsageAndProgress() {
        let keys = [
            usageKey(id: 2, total: 100, used: 25, today: 5, status: "disabled"),
            usageKey(id: 1, total: 400, used: 100, today: 10)
        ]
        let normal = UsageSnapshot(
            weeklyUsage: WeeklyUsage(used: 90, total: 300),
            keys: keys
        )
        let over = UsageSnapshot(
            weeklyUsage: WeeklyUsage(used: 120, total: 100),
            keys: keys
        )
        let invalid = UsageSnapshot(
            weeklyUsage: WeeklyUsage(used: 20, total: 0),
            keys: keys
        )

        require(normal.progress == 0.3, "normal progress")
        require(normal.total == 300, "subscription weekly total")
        require(normal.used == 90, "subscription weekly used")
        require(normal.remaining == 210, "subscription weekly remaining")
        require(normal.keys.count == 1, "active key count")
        require(normal.keys.map(\.id) == [1], "inactive keys excluded from snapshot")
        require(over.progress == 1, "over-quota progress")
        require(over.remaining == 0, "remaining lower bound")
        require(over.isOverQuota, "over-quota flag")
        require(invalid.progress == 0, "zero-quota progress")
    }

    private static func testPreferenceNormalization() {
        require(UserPreferences.normalizedRefreshInterval(1) == 5, "minimum refresh interval")
        require(UserPreferences.normalizedRefreshInterval(10.4) == 10, "rounded refresh interval")
        require(UserPreferences.normalizedRefreshInterval(4_000) == 3_600, "maximum refresh interval")
        require(UserPreferences.normalizedRefreshInterval(.nan) == 10, "invalid refresh interval")

        let preferences = UserPreferences(
            refreshInterval: 30,
            launchAtLogin: true
        )
        require(preferences.launchAtLogin, "launch-at-login preference")
    }

    private static func testPaginationAndDeduplication() async throws {
        let requestedPages = LockedPages()
        let requestedUsageIDs = LockedPages()
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            if url.path == "/api/v1/auth/login" {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"access_token":"test-token","expires_in":3600,"token_type":"bearer"}}"#
                )
            }
            if url.path == "/api/v1/subscriptions" {
                let timezone = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "timezone" })?.value
                guard timezone == "Asia/Shanghai" else {
                    throw APIClientError.invalidResponse
                }
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":[{"status":"active","weekly_usage_usd":52.71,"group":{"weekly_limit_usd":500}}]}"#
                )
            }
            if url.path == "/api/v1/usage/dashboard/api-keys-usage" {
                guard request.httpMethod == "POST" else {
                    throw APIClientError.invalidResponse
                }
                let body = try requestBody(request)
                let payload = try JSONDecoder().decode(APIKeyUsagePayload.self, from: body)
                payload.apiKeyIDs.forEach(requestedUsageIDs.append)
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"stats":{"1":{"api_key_id":1,"today_actual_cost":1.25,"total_actual_cost":10},"2":{"api_key_id":2,"today_actual_cost":8.5,"total_actual_cost":25}}}}"#
                )
            }

            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let page = Int(components?.queryItems?.first(where: { $0.name == "page" })?.value ?? "") ?? 0
            requestedPages.append(page)
            if page == 1 {
                return mockResponse(
                    url: url,
                    json: keyPageJSON(
                        page: 1,
                        items: [
                            #"{"id":1,"name":"One","status":"active","quota":100,"quota_used":10}"#,
                            #"{"id":2,"name":"Two","status":"active","quota":200,"quota_used":20}"#
                        ]
                    )
                )
            }
            return mockResponse(
                url: url,
                json: keyPageJSON(
                    page: 2,
                    items: [
                        #"{"id":2,"name":"Two","status":"active","quota":200,"quota_used":25}"#,
                        #"{"id":3,"name":"Three","status":"disabled","quota":300,"quota_used":30}"#
                    ]
                )
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let usage = try await client.fetchUsage(
            credentials: Credentials(email: "test@example.com", password: "test")
        )

        require(requestedPages.values == [1, 2], "all pages requested")
        require(requestedUsageIDs.values == [1, 2], "today usage requested for active keys only")
        require(usage.keys.map(\.id) == [1, 2], "inactive keys excluded")
        require(usage.keys.first(where: { $0.id == 2 })?.quotaUsed == 25, "duplicate key refreshed")
        require(usage.keys.first(where: { $0.id == 2 })?.todayActualCost == 8.5, "today usage merged by key id")
        require(usage.weeklyUsage.used == 52.71, "weekly usage decoded")
        require(usage.weeklyUsage.total == 500, "nested weekly limit decoded")
    }

    private static func keyPageJSON(page: Int, items: [String]) -> String {
        """
        {"code":0,"message":"success","data":{"items":[\(items.joined(separator: ","))],"total":3,"page":\(page),"page_size":2,"pages":2}}
        """
    }

    private static func mockResponse(url: URL, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static func requireURL(_ request: URLRequest) throws -> URL {
        guard let url = request.url else { throw APIClientError.invalidResponse }
        return url
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw APIClientError.invalidResponse }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? APIClientError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func usageKey(
        id: Int,
        total: Double,
        used: Double,
        today: Double = 0,
        status: String = "active"
    ) -> UsageKey {
        UsageKey(
            id: id,
            name: "Test",
            status: status,
            quota: total,
            quotaUsed: used,
            updatedAt: nil,
            todayActualCost: today
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fatalError("Self-test failed: \(name)")
        }
    }
}

private final class LockedPages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.withLock { storage }
    }

    func append(_ value: Int) {
        lock.withLock { storage.append(value) }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: APIClientError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
