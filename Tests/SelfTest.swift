import AppKit
import Foundation

@main
enum SelfTest {
    static func main() async throws {
        try testDecodesUsageResponse()
        try testDecodesUsageHistory()
        testWeeklyUsageAndProgress()
        testPreferenceNormalization()
        try testStationProfiles()
        try testReleaseResolution()
        try await testUpdateCheckRetry()
        try await testLoginOnlyUsesLoginEndpoint()
        try await testPaginationAndDeduplication()
        try await testAPIKeyQuotaResetRequest()
        try await testOptionalEndpointDegradation()
        testLegacyDefaultsMigration()
        testStatusCatFill()
        testDailyUpdateSchedule()
        testWeeklyResetCalculation()
        testWeeklyResetMonitor()
        try testCredentialFileStorage()
        print("Self-test passed: 17 checks")
    }

    private static func testDecodesUsageHistory() throws {
        let json = #"{"code":0,"message":"success","data":{"items":[{"id":91,"api_key_id":104,"api_key":{"name":"Primary"},"model":"gpt-5.6","reasoning_effort":"high","actual_cost":0.012345,"created_at":"2026-08-12T10:31:58.067319+08:00"},{"id":92,"api_key_id":105,"api_key":null,"model":"gpt-5.6-mini","reasoning_effort":null,"actual_cost":0,"created_at":"2026-08-12T10:30:00+08:00"}],"total":2,"page":1,"page_size":50,"pages":1}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let result = try decoder.decode(APIEnvelope<UsageRecordListData>.self, from: Data(json.utf8))
        require(result.data.items[0].apiKeyName == "Primary", "usage history nested API key name")
        require(result.data.items[0].reasoningEffort == "high", "usage history reasoning effort")
        require(result.data.items[0].actualCost == 0.012345, "usage history actual cost")
        require(result.data.items[1].apiKeyName == "API Key #105", "usage history missing key fallback")
        require(result.data.items[1].reasoningEffort == nil, "usage history optional reasoning effort")
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
              "current_concurrency": 3,
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
        require(result.data.items.first?.concurrency == 3, "current_concurrency")
        require(result.data.items.first?.updatedAt != nil, "updated_at")
        require(result.data.page == 1, "page")
        require(result.data.pageSize == 100, "page_size")
        require(result.data.pages == 1, "pages")
        require(result.data.items.first?.todayActualCost == nil, "today cost is unavailable before usage lookup")
    }

    private static func testWeeklyUsageAndProgress() {
        let keys = [
            usageKey(id: 2, total: 100, used: 25, today: 5, status: "disabled"),
            usageKey(id: 1, total: 400, used: 100, today: 10),
            usageKey(id: 3, total: 50, used: 5, today: 1, status: "inactive")
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
        require(normal.keys.count == 2, "all non-inactive keys retained")
        require(normal.keys.map(\.id) == [1, 2], "only inactive keys excluded from snapshot")
        require(over.progress == 1, "over-quota progress")
        require(over.remaining == 0, "remaining lower bound")
        require(over.isOverQuota, "over-quota flag")
        require(invalid.progress == 0, "zero-quota progress")
        require(normal.keys[0].quota > 0 && normal.keys[0].progress == 0.25, "limited key quota progress")
        let unlimited = usageKey(id: 8, total: 0, used: 20)
        require(unlimited.quota == 0 && unlimited.progress == 0, "unlimited key has no quota progress")
        let unavailable = UsageSnapshot(weeklyUsage: nil, keys: keys)
        require(!unavailable.hasWeeklyUsage, "missing weekly usage remains unavailable")
    }

    private static func testPreferenceNormalization() {
        require(UserPreferences.normalizedRefreshInterval(1) == 5, "minimum refresh interval")
        require(UserPreferences.normalizedRefreshInterval(10.4) == 10, "rounded refresh interval")
        require(UserPreferences.normalizedRefreshInterval(4_000) == 3_600, "maximum refresh interval")
        require(UserPreferences.normalizedRefreshInterval(.nan) == 10, "invalid refresh interval")

        let preferences = UserPreferences(
            refreshInterval: 30,
            launchAtLogin: true,
            showAPIKeyDetails: false,
            showMetricCards: false,
            showUsageHistory: false,
            automaticallyUpdates: false
        )
        require(preferences.launchAtLogin, "launch-at-login preference")
        require(!preferences.showAPIKeyDetails, "API key details preference")
        require(!preferences.showMetricCards, "metric cards preference")
        require(!preferences.showUsageHistory, "usage history preference")
        require(!preferences.automaticallyUpdates, "automatic update preference")

        let suiteName = "dev.ruobin.QuotaBar.SelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)
        let initial = store.load()
        require(initial.showAPIKeyDetails, "API key details default enabled")
        require(initial.showMetricCards, "metric cards default enabled")
        require(initial.showUsageHistory, "usage history default enabled")
        require(initial.automaticallyUpdates, "automatic updates default enabled")
        store.save(preferences)
        require(store.load() == preferences, "display preferences persisted")
    }

    private static func testLegacyDefaultsMigration() {
        let targetSuite = "dev.ruobin.QuotaBar.MigrationSelfTest.\(UUID().uuidString)"
        let legacySuite = "dev.ruobin.OpenAIUsageBar.MigrationSelfTest.\(UUID().uuidString)"
        let target = UserDefaults(suiteName: targetSuite)!
        let legacy = UserDefaults(suiteName: legacySuite)!
        defer {
            target.removePersistentDomain(forName: targetSuite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
        legacy.set(45.0, forKey: "refreshInterval")
        legacy.set(false, forKey: "showMetricCards")
        AppDataMigration.migrateLegacyDefaultsIfNeeded(defaults: target, legacyDomainName: legacySuite)
        require(target.double(forKey: "refreshInterval") == 45, "legacy refresh preference migrated")
        require(target.object(forKey: "showMetricCards") != nil && !target.bool(forKey: "showMetricCards"), "legacy boolean preference migrated")
    }

    @MainActor
    private static func testStatusCatFill() {
        func bitmap(_ progress: Double) -> NSBitmapImageRep {
            let image = StatusRingRenderer.image(progress: progress, phase: .ready)
            return NSBitmapImageRep(data: image.tiffRepresentation!)!
        }

        func greenPixels(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
            rows.reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.greenComponent > 0.45
                        && color.greenComponent > color.redComponent * 1.4
                        && color.alphaComponent > 0.5
                }.count
            }
        }

        let empty = bitmap(0)
        let ten = bitmap(0.1)
        let full = bitmap(1)
        let waveA = StatusRingRenderer.image(progress: 0.5, phase: .ready, wavePhase: 0)
        let waveB = StatusRingRenderer.image(progress: 0.5, phase: .ready, wavePhase: .pi / 2)
        let resting = bitmapImage(StatusRingRenderer.image(progress: 0.5, phase: .ready, tailPhase: .pi * 0.5))
        let twitching = bitmapImage(StatusRingRenderer.image(progress: 0.5, phase: .ready, tailPhase: .pi))
        let split = max(ten.pixelsHigh / 2, 1)
        require(greenPixels(empty, rows: 0..<empty.pixelsHigh) == 0, "zero usage cat remains black")
        require(greenPixels(ten, rows: 0..<ten.pixelsHigh) > 0, "ten percent cat has green fill")
        let tenTop = greenPixels(ten, rows: 0..<split)
        let tenBottom = greenPixels(ten, rows: split..<ten.pixelsHigh)
        require(tenBottom > tenTop, "ten percent green fill stays at cat bottom")
        require(greenPixels(full, rows: 0..<full.pixelsHigh) > greenPixels(ten, rows: 0..<ten.pixelsHigh), "full cat has more green fill")
        require(empty.colorAt(x: 0, y: 0)?.alphaComponent == 0, "status icon has no outer background")
        require(waveA.tiffRepresentation != waveB.tiffRepresentation, "wave phase animates green surface")
        let topEnd = Int(ceil(Double(resting.pixelsHigh) * 0.34))
        var changedTopPixels = 0
        for y in 0..<topEnd {
            for x in 0..<resting.pixelsWide where pixelsDiffer(resting, twitching, x: x, y: y) {
                changedTopPixels += 1
            }
        }
        require(changedTopPixels >= 2, "ear twitch visibly changes the 20px top silhouette")
    }

    private static func bitmapImage(_ image: NSImage) -> NSBitmapImageRep {
        NSBitmapImageRep(data: image.tiffRepresentation!)!
    }

    private static func pixelsDiffer(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let left = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
              let right = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return abs(left.redComponent - right.redComponent) > 0.08
            || abs(left.greenComponent - right.greenComponent) > 0.08
            || abs(left.blueComponent - right.blueComponent) > 0.08
            || abs(left.alphaComponent - right.alphaComponent) > 0.08
    }

    private static func testDailyUpdateSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = ISO8601DateFormatter()
        let morning = formatter.date(from: "2026-08-13T03:00:00Z")!
        let noon = formatter.date(from: "2026-08-13T04:00:00Z")!
        let afternoon = formatter.date(from: "2026-08-13T05:00:00Z")!
        require(DailyUpdateSchedule.nextNoon(after: morning, calendar: calendar) == noon, "update schedules today's noon")
        require(!DailyUpdateSchedule.isDue(now: morning, lastCheck: nil, calendar: calendar), "automatic update waits until noon")
        require(DailyUpdateSchedule.isDue(now: afternoon, lastCheck: nil, calendar: calendar), "automatic update catches missed noon")
        require(!DailyUpdateSchedule.isDue(now: afternoon, lastCheck: noon, calendar: calendar), "automatic update runs once per day")
    }

    private static func testWeeklyResetCalculation() {
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-08-11T01:37:50Z")!
        let beforeReset = formatter.date(from: "2026-08-12T08:00:00Z")!
        let reset = WeeklyResetCalculator.nextReset(windowStart: start, expiresAt: nil, now: beforeReset)
        require(reset == start.addingTimeInterval(7 * 86_400), "weekly reset follows seven-day window")

        let afterFirstReset = formatter.date(from: "2026-08-19T08:00:00Z")!
        let secondReset = WeeklyResetCalculator.nextReset(windowStart: start, expiresAt: nil, now: afterFirstReset)
        require(secondReset == start.addingTimeInterval(14 * 86_400), "weekly reset advances across periods")

        let expiry = start.addingTimeInterval(7 * 86_400)
        require(
            WeeklyResetCalculator.nextReset(windowStart: start, expiresAt: expiry, now: beforeReset) == nil,
            "subscription expiry suppresses later weekly reset"
        )
    }

    private static func testWeeklyResetMonitor() {
        let suiteName = "dev.ruobin.QuotaBar.ResetMonitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = WeeklyResetMonitor(defaults: defaults)
        let profileID = UUID()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: first,
                enabled: false, visibleKeyIDs: [105, 106]
            ).isEmpty,
            "disabled reset monitoring does nothing"
        )
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: first,
                enabled: true, visibleKeyIDs: [105, 106]
            ).isEmpty,
            "first reset observation establishes baseline"
        )
        require(
            monitor.resetPlan(
                profileID: profileID,
                subscriptionID: 10,
                resetAt: first.addingTimeInterval(-60),
                enabled: true,
                visibleKeyIDs: [105, 106]
            ).isEmpty,
            "countdown decrease does not trigger reset"
        )
        let nextCycle = first.addingTimeInterval(7 * 86_400)
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: nextCycle,
                enabled: true, visibleKeyIDs: [106, 105]
            ) == [105, 106],
            "forward reset-time jump triggers quota reset"
        )
        monitor.markKeyHandled(profileID: profileID, keyID: 105)
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: nextCycle,
                enabled: true, visibleKeyIDs: [105]
            ).isEmpty,
            "inactive pending keys are dropped before retry"
        )
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 11, resetAt: nextCycle,
                enabled: true, visibleKeyIDs: [105, 106]
            ).isEmpty,
            "subscription change establishes a new baseline"
        )
    }

    private static func testAPIKeyQuotaResetRequest() async throws {
        let requestedIDs = LockedPages()
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            if url.path.hasSuffix("/api/v1/auth/login") {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"access_token":"reset-token"}}"#
                )
            }
            guard request.httpMethod == "PUT",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer reset-token",
                  let id = Int(url.lastPathComponent) else {
                throw APIClientError.invalidResponse
            }
            let body = try requestBody(request)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Bool]
            require(object == ["reset_quota": true], "quota reset sends only reset_quota")
            requestedIDs.append(id)
            return mockResponse(
                url: url,
                json: #"{"code":0,"message":"success","data":{"id":1}}"#
            )
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let profile = StationProfile(name: "Reset", serviceURL: "https://relay.example.com")
        let credentials = Credentials(email: "test@example.com", password: "test")
        try await client.resetAPIKeyQuota(profile: profile, credentials: credentials, keyID: 105)
        try await client.resetAPIKeyQuota(profile: profile, credentials: credentials, keyID: 106)
        require(requestedIDs.values == [105, 106], "all visible API key quotas reset")
    }

    private static func testCredentialFileStorage() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-CredentialTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = CredentialStore(baseDirectory: baseDirectory)
        let profileID = UUID()
        let expected = Credentials(email: "local@example.com", password: "secret")
        let missingCredentials = try store.load(for: profileID)
        require(missingCredentials == nil, "missing local credential is nil")
        try store.save(expected, for: profileID)
        let loadedCredentials = try store.load(for: profileID)
        require(loadedCredentials == expected, "local credential round trip")

        let directory = baseDirectory.appending(path: "QuotaBar", directoryHint: .isDirectory)
        let file = directory.appending(path: "credentials.json")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        require(directoryMode?.intValue == 0o700, "credential directory permissions")
        require(fileMode?.intValue == 0o600, "credential file permissions")
        try store.delete(for: profileID)
        let deletedCredentials = try store.load(for: profileID)
        require(deletedCredentials == nil, "local credential deleted")
    }

    private static func testStationProfiles() throws {
        let profile = try StationProfile(
            name: " Proxy ",
            serviceURL: "https://relay.example.com/panel/",
            apiPath: "api/v1/",
            timezone: "Asia/Shanghai"
        ).validated()
        require(profile.name == "Proxy", "station name normalized")
        require(profile.serviceURL == "https://relay.example.com/panel", "service URL normalized")
        require(profile.apiPath == "/api/v1", "API path normalized")
        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","serviceURL":"https://relay.example.com","apiPath":"/api/v1","timezone":"Asia/Shanghai","subscriptionSelection":{"mode":"automatic"},"capabilities":[]}"#
        let legacy = try JSONDecoder().decode(StationProfile.self, from: Data(legacyJSON.utf8))
        require(!legacy.automaticallyResetsAPIKeyQuota, "legacy station defaults automatic quota reset off")
        require(profile.apiBaseURL?.absoluteString == "https://relay.example.com/panel/api/v1", "path prefix preserved")
        require((try? StationProfile(name: "HTTP", serviceURL: "http://example.com").validated()) == nil, "HTTP rejected")
        require((try? StationProfile(name: "Secret", serviceURL: "https://user:pass@example.com").validated()) == nil, "URL credentials rejected")

        let rangeNow = ISO8601DateFormatter().date(from: "2026-08-11T16:30:00Z")!
        let shanghaiRange = try UsageHistoryDateRange(timezone: "Asia/Shanghai", now: rangeNow)
        let losAngelesRange = try UsageHistoryDateRange(timezone: "America/Los_Angeles", now: rangeNow)
        require(shanghaiRange.startDate == "2026-08-11" && shanghaiRange.endDate == "2026-08-12", "Shanghai local date range")
        require(losAngelesRange.startDate == "2026-08-10" && losAngelesRange.endDate == "2026-08-11", "Los Angeles local date range")

        let suiteName = "dev.ruobin.QuotaBar.StationSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(profiles: [profile], activeProfileID: profile.id))
        require(profileStore.load().profiles == [profile], "station profiles persisted")
        require(profileStore.load().activeProfileID == profile.id, "active profile persisted")
    }

    private static func testReleaseResolution() throws {
        require(SemanticVersion("1.7.3")! > SemanticVersion("1.7.2")!, "semantic version ordering")
        require(SemanticVersion("v2.0")! == SemanticVersion("2.0.0")!, "semantic version normalization")

        let release = GitHubRelease(
            tagName: "v1.11.0",
            htmlURL: URL(string: "https://github.com/vincent-liuc/QuotaBar/releases/tag/v1.11.0")!,
            assets: [
                .init(
                    name: "QuotaBar-1.11.0-universal.dmg",
                    url: URL(string: "https://api.github.com/repos/vincent-liuc/QuotaBar/releases/assets/1")!,
                    browserDownloadURL: URL(string: "https://example.com/app.dmg")!
                ),
                .init(
                    name: "QuotaBar-1.11.0-universal.dmg.sha256",
                    url: URL(string: "https://api.github.com/repos/vincent-liuc/QuotaBar/releases/assets/2")!,
                    browserDownloadURL: URL(string: "https://example.com/app.dmg.sha256")!
                )
            ]
        )
        guard case .available(let update) = try ReleaseResolver.resolve(
            release,
            currentVersion: "1.7.3"
        ) else {
            fatalError("Self-test failed: update release available")
        }
        require(update.version == "1.11.0", "update version normalized")
        require(update.fileName.hasSuffix("universal.dmg"), "universal DMG selected")
        require(update.downloadAPIURL.host == "api.github.com", "asset API URL selected")
        guard case .upToDate(let latest) = try ReleaseResolver.resolve(
            release,
            currentVersion: "1.11.0"
        ) else {
            fatalError("Self-test failed: up-to-date release")
        }
        require(latest == "1.11.0", "latest version reported")
    }

    private static func testUpdateCheckRetry() async throws {
        let attempts = LockedPages()
        MockURLProtocol.requestHandler = { request in
            attempts.append(1)
            if attempts.values.count == 1 { throw URLError(.timedOut) }
            let url = try requireURL(request)
            require(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "release accept header")
            return mockResponse(
                url: url,
                json: #"{"tag_name":"v1.11.0","html_url":"https://github.com/vincent-liuc/QuotaBar/releases/tag/v1.11.0","assets":[]}"#
            )
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let updater = AppUpdater(
            session: URLSession(configuration: configuration),
            latestReleaseURL: URL(string: "https://api.github.com/repos/vincent-liuc/QuotaBar/releases/latest")!
        )
        guard case .upToDate(let version) = try await updater.checkForUpdate(currentVersion: "1.11.0") else {
            fatalError("Self-test failed: update check retry result")
        }
        require(version == "1.11.0", "update check succeeds after timeout retry")
        require(attempts.values.count == 2, "update check retries transient timeout")
    }

    private static func testLoginOnlyUsesLoginEndpoint() async throws {
        let requestedPaths = LockedStrings()
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            requestedPaths.append(url.path)
            return mockResponse(
                url: url,
                json: #"{"code":0,"message":"success","data":{"access_token":"login-test-token"}}"#
            )
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        try await client.testLogin(
            profile: StationProfile(name: "Login", serviceURL: "https://relay.example.com"),
            credentials: Credentials(email: "test@example.com", password: "test")
        )
        require(requestedPaths.values == ["/api/v1/auth/login"], "login test only requests login endpoint")
    }

    private static func testPaginationAndDeduplication() async throws {
        let requestedPages = LockedPages()
        let requestedUsageIDs = LockedPages()
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            if url.path.hasSuffix("/api/v1/auth/login") {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"access_token":"test-token","expires_in":3600,"token_type":"bearer"}}"#
                )
            }
            if url.path.hasSuffix("/api/v1/subscriptions") {
                let timezone = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "timezone" })?.value
                guard timezone == "Asia/Shanghai" else {
                    throw APIClientError.invalidResponse
                }
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":[{"id":10,"name":"Weekly","status":"active","weekly_usage_usd":52.71,"weekly_window_start":"2026-08-11T09:37:50+08:00","expires_at":"2026-09-14T13:42:26+08:00","group":{"weekly_limit_usd":500}}]}"#
                )
            }
            if url.path.hasSuffix("/api/v1/usage/dashboard/stats") {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"total_tokens":137630389,"total_actual_cost":106.38925756}}"#
                )
            }
            if url.path.hasSuffix("/api/v1/usage/dashboard/api-keys-usage") {
                guard request.httpMethod == "POST" else {
                    throw APIClientError.invalidResponse
                }
                let body = try requestBody(request)
                let payload = try JSONDecoder().decode(APIKeyUsagePayload.self, from: body)
                payload.apiKeyIDs.forEach(requestedUsageIDs.append)
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"stats":{"2":{"api_key_id":2,"today_actual_cost":8.5,"total_actual_cost":25}}}}"#
                )
            }
            if url.path.hasSuffix("/api/v1/usage") {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func query(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
                require(query("page_size") == "50", "usage history requests 50 records")
                require(query("sort_by") == "created_at" && query("sort_order") == "desc", "usage history sort")
                require(query("timezone") == "Asia/Shanghai", "usage history station timezone")
                require(query("start_date") != nil && query("end_date") != nil, "usage history date range")
                let records = (1...12).map { index in
                    #"{"id":\#(index),"api_key_id":1,"api_key":{"name":"One"},"model":"gpt-5.6","reasoning_effort":"medium","actual_cost":0.01,"created_at":"2026-08-12T10:31:58+08:00"}"#
                }.joined(separator: ",")
                return mockResponse(url: url, json: #"{"code":0,"message":"success","data":{"items":[\#(records)],"total":12,"page":1,"page_size":50,"pages":1}}"#)
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
                            #"{"id":1,"name":"One","status":"active","quota":100,"quota_used":10,"current_concurrency":2}"#,
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
            profile: StationProfile(
                name: "Test",
                serviceURL: "https://relay.example.com/proxy",
                timezone: "Asia/Shanghai",
                subscriptionSelection: .manual(10)
            ),
            credentials: Credentials(email: "test@example.com", password: "test")
        )

        require(requestedPages.values == [1, 2], "all pages requested")
        require(requestedUsageIDs.values == [1, 2, 3], "today usage excludes inactive keys only")
        require(usage.keys.map(\.id) == [1, 2, 3], "only inactive keys excluded")
        require(usage.keys.first(where: { $0.id == 2 })?.quotaUsed == 25, "duplicate key refreshed")
        require(usage.keys.first(where: { $0.id == 2 })?.todayActualCost == 8.5, "today usage merged by key id")
        require(usage.keys.first(where: { $0.id == 1 })?.todayActualCost == 0, "missing stat is zero when endpoint succeeds")
        require(usage.keys.first(where: { $0.id == 1 })?.concurrency == 2, "current concurrency retained")
        require(usage.weeklyUsage?.used == 52.71, "weekly usage decoded")
        require(usage.weeklyUsage?.total == 500, "nested weekly limit decoded")
        require(usage.weeklyUsage?.resetAt != nil, "weekly reset derived from window start")
        require(usage.accountMetrics?.totalTokens == 137_630_389, "total tokens decoded")
        require(usage.accountMetrics?.totalActualCost == 106.38925756, "total actual cost decoded")
        require(usage.capabilities.contains(.apiKeyDailyUsage), "daily usage capability detected")
        require(usage.capabilities.contains(.usageHistory), "usage history capability detected")
        require(usage.usageRecords?.count == 12, "all fetched usage history retained in data layer")
        let snapshot = UsageSnapshot(weeklyUsage: usage.weeklyUsage, keys: usage.keys, usageRecords: usage.usageRecords)
        require(snapshot.usageRecords?.count == 12, "dashboard retains fetched usage history for scrolling")
    }

    private static func testOptionalEndpointDegradation() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            require(url.host == "another.example.com", "dynamic station host used")
            require(url.path.hasPrefix("/sub/api/v1/"), "reverse proxy prefix used")
            if url.path.hasSuffix("/auth/login") {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"access_token":"token"}}"#
                )
            }
            if url.path.hasSuffix("/keys") {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"items":[{"id":4,"name":"Core","status":"active","quota":10,"quota_used":1}],"total":1,"page":1,"page_size":100,"pages":1}}"#
                )
            }
            return mockResponse(url: url, json: #"{"code":404,"message":"unsupported","data":{}}"#, status: 404)
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let usage = try await client.fetchUsage(
            profile: StationProfile(name: "Old", serviceURL: "https://another.example.com/sub"),
            credentials: Credentials(email: "old@example.com", password: "password")
        )
        require(usage.keys.count == 1, "core keys survive optional endpoint failures")
        require(usage.weeklyUsage == nil, "missing subscription is unavailable")
        require(usage.accountMetrics == nil, "missing metrics are unavailable")
        require(usage.keys[0].todayActualCost == nil, "missing daily usage is not zero")
        require(usage.usageRecords == nil, "missing usage history is unavailable")
        require(usage.capabilities.isEmpty, "unsupported capabilities excluded")
    }

    private static func keyPageJSON(page: Int, items: [String]) -> String {
        """
        {"code":0,"message":"success","data":{"items":[\(items.joined(separator: ","))],"total":3,"page":\(page),"page_size":2,"pages":2}}
        """
    }

    private static func mockResponse(url: URL, json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
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

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
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
