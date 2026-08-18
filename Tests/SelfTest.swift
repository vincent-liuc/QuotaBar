import AppKit
import Foundation

@main
enum SelfTest {
    static func main() async throws {
        try testDecodesUsageResponse()
        try testDecodesSub2APIUsageKeyGroup()
        try testDecodesUsageHistory()
        testWeeklyUsageAndProgress()
        testPreferenceNormalization()
        try testStationProfiles()
        try testReleaseResolution()
        try await testUpdateCheckRetry()
        try await testLoginOnlyUsesLoginEndpoint()
        try await testNewAPILoginContract()
        try await testStationProbeRecognizesSub2API()
        try await testStationProbePreservesTemporaryFailure()
        testDashboardIssueClassification()
        try await testUsageStoreOnboardingState()
        try await testUsageStoreLatestRefreshWins()
        try await testPaginationAndDeduplication()
        try await testAPIKeyQuotaResetRequest()
        try await testOptionalEndpointDegradation()
        try await testNewAPIFullUsageMapping()
        testLegacyDefaultsMigration()
        testStatusCatFill()
        testDailyUpdateSchedule()
        testWeeklyResetCalculation()
        testWeeklyResetMonitor()
        try testCredentialFileStorage()
        print("Self-test passed: 24 checks")
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

    private static func testDecodesSub2APIUsageKeyGroup() throws {
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
              "group": {"id": 13, "name": "2002", "ratio": 1},
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
        require(result.data.items.first?.group == "2002", "Sub2API object group decodes to group name")

        let stringJSON = #"{"code":0,"message":"success","data":{"items":[{"id":105,"name":"String Group","status":"active","quota":1,"quota_used":0,"group":"default"}],"total":1}}"#
        let stringResult = try decoder.decode(APIEnvelope<KeyListData>.self, from: Data(stringJSON.utf8))
        require(stringResult.data.items.first?.group == "default", "string group remains supported")
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
        require(UserPreferences.normalizedRefreshInterval(1) == 5, "minimum refresh option")
        require(UserPreferences.normalizedRefreshInterval(10.4) == 10, "nearest refresh option")
        require(UserPreferences.normalizedRefreshInterval(45) == 60, "refresh option tie favors lower frequency")
        require(UserPreferences.normalizedRefreshInterval(4_000) == 60, "maximum refresh option")
        require(UserPreferences.normalizedRefreshInterval(.nan) == 60, "invalid refresh interval uses default")

        let preferences = UserPreferences(
            refreshInterval: 30,
            launchAtLogin: true,
            showAPIKeyDetails: false,
            showMetricCards: false,
            showSubscriptionQuota: false,
            showUsageHistory: false,
            showDailyUsage: false,
            automaticallyUpdates: false
        )
        require(preferences.launchAtLogin, "launch-at-login preference")
        require(!preferences.showAPIKeyDetails, "API key details preference")
        require(!preferences.showMetricCards, "metric cards preference")
        require(!preferences.showSubscriptionQuota, "subscription quota preference")
        require(!preferences.showUsageHistory, "usage history preference")
        require(!preferences.showDailyUsage, "daily usage preference")
        require(!preferences.automaticallyUpdates, "automatic update preference")

        let suiteName = "dev.ruobin.QuotaBar.SelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)
        let initial = store.load()
        require(initial.refreshInterval == 60, "refresh interval defaults to one minute")
        require(initial.showAPIKeyDetails, "API key details default enabled")
        require(initial.showMetricCards, "metric cards default enabled")
        require(initial.showSubscriptionQuota, "subscription quota default enabled")
        require(initial.showUsageHistory, "usage history default enabled")
        require(initial.showDailyUsage, "daily usage default enabled")
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
            require(!image.isTemplate, "status icon preserves its colored progress surface")
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

        func averageBrightness(_ bitmap: NSBitmapImageRep) -> CGFloat {
            var total: CGFloat = 0
            var count: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.5 else { continue }
                    total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    count += 1
                }
            }
            return count > 0 ? total / count : 0
        }

        let empty = bitmap(0)
        let ten = bitmap(0.1)
        let full = bitmap(1)
        let waveA = StatusRingRenderer.image(progress: 0.5, phase: .ready, wavePhase: 0)
        let waveB = StatusRingRenderer.image(progress: 0.5, phase: .ready, wavePhase: .pi / 2)
        let leftEar = bitmapImage(StatusRingRenderer.image(progress: 0.5, phase: .ready, tailPhase: .pi * 1.5))
        let rightEar = bitmapImage(StatusRingRenderer.image(progress: 0.5, phase: .ready, tailPhase: .pi * 0.5))
        let split = max(ten.pixelsHigh / 2, 1)
        require(greenPixels(empty, rows: 0..<empty.pixelsHigh) == 0, "zero usage cat remains black")
        require(greenPixels(ten, rows: 0..<ten.pixelsHigh) > 0, "ten percent cat has green fill")
        let tenTop = greenPixels(ten, rows: 0..<split)
        let tenBottom = greenPixels(ten, rows: split..<ten.pixelsHigh)
        require(tenBottom > tenTop, "ten percent green fill stays at cat bottom")
        require(greenPixels(full, rows: 0..<full.pixelsHigh) < greenPixels(ten, rows: 0..<ten.pixelsHigh), "high usage cat leaves the green threshold")
        require(empty.colorAt(x: 0, y: 0)?.alphaComponent == 0, "status icon has no outer background")
        require(waveA.tiffRepresentation != waveB.tiffRepresentation, "wave phase animates green surface")

        func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let resolved = color.usingColorSpace(.deviceRGB) ?? .black
            return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }
        func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
            let left = rgb(lhs)
            let right = rgb(rhs)
            return abs(left.0 - right.0) < 0.02
                && abs(left.1 - right.1) < 0.02
                && abs(left.2 - right.2) < 0.02
        }
        require(colorsMatch(StatusRingRenderer.color(for: 0.69), .systemGreen), "status color stays green below warning threshold")
        require(colorsMatch(StatusRingRenderer.color(for: 0.70), .systemOrange), "status color turns orange at warning threshold")
        require(colorsMatch(StatusRingRenderer.color(for: 0.90), .systemRed), "status color turns red at critical threshold")

        var light: NSBitmapImageRep!
        var dark: NSBitmapImageRep!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = bitmap(0) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = bitmap(0) }
        require(averageBrightness(light) < 0.35, "light menu bar uses a dark cat silhouette")
        require(averageBrightness(dark) > 0.65, "dark menu bar uses a light cat silhouette")
        let topEnd = Int(ceil(Double(leftEar.pixelsHigh) * 0.40))
        var changedTopPixels = 0
        for y in 0..<topEnd {
            for x in 0..<leftEar.pixelsWide where pixelsDiffer(leftEar, rightEar, x: x, y: y) {
                changedTopPixels += 1
            }
        }
        require(changedTopPixels >= 6, "left ear swing visibly changes the 20px top silhouette")
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
        let newAPIProfile = try StationProfile(
            name: "New API",
            kind: .newAPI,
            serviceURL: "https://new.example.com"
        ).validated()
        require(newAPIProfile.apiPath == "/api", "New API default path")
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

    private static func testNewAPILoginContract() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            require(url.path == "/api/user/login", "New API login route")
            require(request.httpMethod == "POST", "New API login posts credentials")
            require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "turnstile", "New API login sends turnstile parameter")
            let body = try requestBody(request)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
            require(object?["username"] == "vincentc" && object?["password"] == "secret", "New API login payload uses username and password")
            return mockResponse(url: url, json: #"{"success":true,"message":"","data":{"id":3010,"username":"vincentc","display_name":"Vincent","group":"default","role":1,"status":1}}"#)
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        try await client.testLogin(
            profile: StationProfile(name: "New API", kind: .newAPI, serviceURL: "https://new.example.com"),
            credentials: Credentials(email: "vincentc", password: "secret")
        )
    }

    private static func testStationProbeRecognizesSub2API() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            require(url.path == "/api/v1/auth/login", "station probe uses login route")
            require(request.httpMethod == "POST", "station probe posts empty credentials")
            return mockResponse(
                url: url,
                json: #"{"code":400,"message":"Invalid request"}"#,
                status: 400
            )
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        try await client.testStation(profile: StationProfile(name: "Probe", serviceURL: "https://relay.example.com"))
    }

    private static func testStationProbePreservesTemporaryFailure() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            return mockResponse(
                url: url,
                json: #"{"code":503,"message":"temporarily unavailable"}"#,
                status: 503
            )
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        do {
            try await client.testStation(profile: StationProfile(name: "Probe", serviceURL: "https://relay.example.com"))
            fatalError("Self-test failed: station probe temporary failure")
        } catch APIClientError.httpStatus(503) {
            // Expected: temporary server failures must not become incompatible-station errors.
        }
    }

    @MainActor
    private static func testUsageStoreOnboardingState() async throws {
        let suiteName = "dev.ruobin.QuotaBar.StoreSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-StoreSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let client = OnboardingUsageClient()
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: StationProfileStore(defaults: defaults),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )

        require(store.configurationProgress == ConfigurationProgress(stationIsValid: false, accountIsValid: false), "first install starts at step zero")
        require(store.phase == .needsConfiguration, "first install shows onboarding")

        guard let initialProfile = store.activeProfile else {
            fatalError("Self-test failed: onboarding profile exists")
        }
        try await store.updateStationProfile(initialProfile)
        require(store.configurationProgress == ConfigurationProgress(stationIsValid: true, accountIsValid: false), "station validation completes first step")

        let credentials = Credentials(email: "test@example.com", password: "password")
        _ = try await store.testConnection(profile: initialProfile, credentials: credentials)
        require(store.configurationProgress.isComplete, "complete connection test validates both onboarding steps")

        try await store.updateCredentials(
            credentials,
            for: initialProfile.id
        )
        try await waitUntil { store.phase == .ready }
        require(store.configurationProgress.isComplete, "successful dashboard load completes both steps")
        require(store.snapshot != nil, "completed onboarding loads dashboard")

        await client.setFetchError(.authenticationFailed)
        await store.refresh()
        guard case .failed(let authenticationIssue) = store.phase else {
            fatalError("Self-test failed: authentication failure phase")
        }
        require(authenticationIssue.kind == .authentication, "expired login opens account recovery")
        require(store.configurationProgress == ConfigurationProgress(stationIsValid: true, accountIsValid: false), "authentication failure clears only account step")

        await client.setFetchError(nil)
        await store.refresh()
        require(store.configurationProgress.isComplete, "successful retry restores account validation")
        try credentialStore.delete(for: initialProfile.id)
        await store.refresh()
        require(store.phase == .needsConfiguration, "missing credential returns to onboarding")
        require(!store.configurationProgress.accountIsValid, "missing credential cannot remain completed")

        try credentialStore.save(credentials, for: initialProfile.id)
        try await store.updateCredentials(Credentials(email: "", password: ""), for: initialProfile.id)
        require(store.credentials(for: initialProfile.id) == nil, "empty account fields clear stored credentials")

        await client.setStationError(.httpStatus(503))
        do {
            try await store.updateStationProfile(store.activeProfile!)
            fatalError("Self-test failed: store temporary station failure")
        } catch APIClientError.httpStatus(503) {}
        guard case .failed(let temporaryIssue) = store.phase else {
            fatalError("Self-test failed: temporary station phase")
        }
        require(temporaryIssue.kind == .temporary && temporaryIssue.settingsTab == nil, "temporary station failure avoids settings redirect")
        require(store.configurationProgress.stationIsValid, "temporary failure preserves validated station")
    }

    @MainActor
    private static func testUsageStoreLatestRefreshWins() async throws {
        let suiteName = "dev.ruobin.QuotaBar.RefreshRaceSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-RefreshRaceSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let oldProfile = StationProfile(
            name: "Old",
            serviceURL: "https://old.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let newProfile = StationProfile(
            name: "New",
            serviceURL: "https://new.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(
            profiles: [oldProfile, newProfile],
            activeProfileID: oldProfile.id
        ))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: oldProfile.id)
        try credentialStore.save(credentials, for: newProfile.id)

        let client = ControlledRefreshUsageClient()
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )

        let oldRefresh = Task { await store.refresh() }
        await client.waitUntilStarted(profileID: oldProfile.id)
        require(store.isRefreshing, "old refresh begins")

        let profileSwitch = Task { try await store.selectProfile(newProfile.id) }
        await client.waitUntilStarted(profileID: newProfile.id)
        require(store.activeProfileID == newProfile.id, "new profile becomes active before response")
        require(store.isRefreshing, "new refresh remains active")

        await client.complete(profileID: oldProfile.id, totalActualCost: 1)
        await oldRefresh.value
        require(store.snapshot == nil, "late old response cannot publish snapshot")
        require(store.phase == .loading, "late old response cannot publish phase")
        require(store.isRefreshing, "old defer cannot clear new refresh state")

        await client.complete(profileID: newProfile.id, totalActualCost: 2)
        try await profileSwitch.value
        require(store.phase == .ready, "latest refresh publishes ready phase")
        require(store.snapshot?.accountMetrics?.totalActualCost == 2, "latest refresh publishes new profile snapshot")
        require(!store.isRefreshing, "latest refresh clears its own state")
        let resetCallCount = await client.resetCallCount
        require(resetCallCount == 0, "refresh race test never resets API key quotas")
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func testDashboardIssueClassification() {
        let unauthorized = DashboardIssue.classify(APIClientError.httpStatus(401))
        require(unauthorized.kind == .authentication, "401 classified as authentication")
        require(unauthorized.message == "登录信息有误，请调整后再试", "authentication message is exact")
        require(unauthorized.settingsTab == .account, "authentication opens account tab")

        let disabled = DashboardIssue.classify(APIClientError.httpStatus(403))
        require(disabled.kind == .authentication, "403 classified as authentication")
        let loginValidation = DashboardIssue.classify(APIClientError.authenticationFailed)
        require(loginValidation.kind == .authentication, "login 400/422 classified with request context")
        require(DashboardIssue.classify(StationProfileError.missingCredentials).settingsTab == .account, "missing credentials open account tab")
        require(DashboardIssue.classify(APIClientError.httpStatus(400)).kind == .unknown, "non-login 400 is not authentication")
        let incompatible = DashboardIssue.classify(APIClientError.httpStatus(404))
        require(incompatible.kind == .station && incompatible.settingsTab == .station, "404 opens station tab")
        let malformed = DashboardIssue.classify(APIClientError.invalidResponse)
        require(malformed.kind == .station, "invalid response classified as station")
        let dns = DashboardIssue.classify(URLError(.cannotFindHost))
        require(dns.kind == .station && dns.settingsTab == .station, "DNS error opens station tab")

        for error in [APIClientError.httpStatus(429), .httpStatus(503)] {
            let issue = DashboardIssue.classify(error)
            require(issue.kind == .temporary && issue.settingsTab == nil, "transient HTTP error avoids settings redirect")
        }
        let timeout = DashboardIssue.classify(URLError(.timedOut))
        require(timeout.kind == .temporary && timeout.settingsTab == nil, "timeout remains retryable")

        let progress = ConfigurationProgress(stationIsValid: true, accountIsValid: false)
        require(!progress.isComplete, "configuration requires both steps")
        require(ConfigurationProgress(stationIsValid: true, accountIsValid: true).isComplete, "configuration completes after both steps")
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
                    json: #"{"code":0,"message":"success","data":[{"id":10,"name":"Weekly","status":"active","weekly_usage_usd":52.71,"daily_usage_usd":6.25,"daily_window_start":"2026-08-17T09:37:50+08:00","weekly_window_start":"2026-08-11T09:37:50+08:00","expires_at":"2026-09-14T13:42:26+08:00","group":{"weekly_limit_usd":500,"daily_limit_usd":20}}]}"#
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
        require(usage.dailyUsage?.used == 6.25, "daily subscription usage decoded")
        require(usage.dailyUsage?.total == 20, "nested daily limit decoded")
        require(usage.dailyUsage?.subscriptionName == "Weekly", "daily usage uses selected subscription")
        require(usage.accountMetrics?.totalTokens == 137_630_389, "total tokens decoded")
        require(usage.accountMetrics?.totalActualCost == 106.38925756, "total actual cost decoded")
        require(usage.capabilities.contains(.apiKeyDailyUsage), "daily usage capability detected")
        require(usage.capabilities.contains(.usageHistory), "usage history capability detected")
        require(usage.usageRecords?.count == 12, "all fetched usage history retained in data layer")
        let snapshot = UsageSnapshot(weeklyUsage: usage.weeklyUsage, dailyUsage: usage.dailyUsage, keys: usage.keys, usageRecords: usage.usageRecords)
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

    private static func testNewAPIFullUsageMapping() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            switch url.path {
            case "/api/user/login":
                return mockResponse(url: url, json: #"{"success":true,"message":"","data":{"id":3010,"username":"vincentc","display_name":"Vincent","group":"default","role":1,"status":1}}"#)
            case "/api/status":
                return mockResponse(url: url, json: #"{"success":true,"message":"success","data":{"quota_per_unit":500000,"turnstile_check":false,"display_in_currency":true,"quota_display_type":"USD","usd_exchange_rate":1}}"#)
            case "/api/user/self":
                require(request.value(forHTTPHeaderField: "Authorization") == nil, "cookie login does not send an empty bearer header")
                require(request.value(forHTTPHeaderField: "New-API-User") == "3010", "New API user header")
                return mockResponse(url: url, json: #"{"success":true,"message":"success","data":{"id":3010,"quota":1115400000,"used_quota":385100000,"request_count":42}}"#)
            case "/api/token":
                require(url.absoluteString.contains("/api/token/?"), "New API token list uses canonical trailing slash")
                require(request.value(forHTTPHeaderField: "New-API-User") == "3010", "token list user header")
                return mockResponse(url: url, json: #"{"success":true,"message":"success","data":{"page":1,"page_size":100,"total":2,"items":[{"id":7,"status":1,"name":"Primary","created_time":1786670000,"accessed_time":1786671000,"remain_quota":0,"unlimited_quota":true,"used_quota":50000,"group":"GPT_high"},{"id":8,"status":2,"name":"Disabled","created_time":1786670000,"accessed_time":1786671000,"remain_quota":100000,"unlimited_quota":false,"used_quota":10000,"group":"default"}]}}"#)
            case "/api/data/self":
                return mockResponse(url: url, json: #"{"success":true,"message":"success","data":[{"id":1,"user_id":3010,"username":"vincentc","model_name":"gpt-5.6","created_at":1786671000,"token_used":123,"count":2,"quota":100000},{"id":2,"user_id":3010,"username":"vincentc","model_name":"gpt-5.6","created_at":1786671000,"token_used":456,"count":3,"quota":200000}]}"#)
            case "/api/log/self/stat":
                let tokenName = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token_name" })?.value
                require(tokenName == "Primary", "daily stat filters exact token name")
                return mockResponse(url: url, json: #"{"success":true,"message":"success","data":{"quota":100000,"rpm":2,"tpm":1000}}"#)
            case "/api/log/self":
                return mockResponse(url: url, json: #"{"success":true,"message":"success","data":{"page":1,"page_size":50,"total":1,"items":[{"id":99,"user_id":3010,"created_at":1786671000,"type":0,"content":"","username":"vincentc","token_name":"Primary","model_name":"gpt-5.6","quota":150000,"prompt_tokens":100,"completion_tokens":20,"use_time":2,"is_stream":true,"channel":1,"channel_name":"main","token_id":7,"group":"GPT_high","ip":"","request_id":"req","other":"{\"reasoning_effort\":\"high\"}"}]}}"#)
            default:
                throw APIClientError.invalidResponse
            }
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let usage = try await client.fetchUsage(
            profile: StationProfile(name: "New API", kind: .newAPI, serviceURL: "https://new.example.com", timezone: "Asia/Shanghai"),
            credentials: Credentials(email: "vincentc", password: "secret")
        )
        require(usage.keys.count == 1 && usage.keys[0].id == 7, "New API filters disabled tokens")
        require(usage.keys[0].quota == 0 && usage.keys[0].quotaUsed == 0.1, "New API unlimited token remains unlimited")
        require(usage.keys[0].todayActualCost == 0.2, "New API daily token cost converted")
        require(usage.keys[0].group == "GPT_high", "New API token group mapped")
        require(usage.weeklyUsage?.kind == .accountPool, "New API account pool quota mapped")
        require(usage.weeklyUsage?.used == 770.2 && usage.weeklyUsage?.total == 3001, "New API account total combines balance and historical consumption")
        require(usage.accountMetrics?.balance == 2230.8 && usage.accountMetrics?.totalActualCost == 770.2, "New API balance and cost converted")
        require(usage.accountMetrics?.requestCount == 42 && usage.accountMetrics?.totalTokens == 579, "New API account metrics mapped")
        require(usage.usageRecords?.first?.actualCost == 0.3 && usage.usageRecords?.first?.reasoningEffort == "high", "New API log fields mapped")
        require(usage.capabilities == [.accountMetrics, .apiKeyDailyUsage, .usageHistory], "New API capabilities detected")
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

private actor OnboardingUsageClient: UsageFetching {
    private var fetchError: APIClientError?
    private var stationError: APIClientError?

    func setFetchError(_ error: APIClientError?) {
        fetchError = error
    }

    func setStationError(_ error: APIClientError?) {
        stationError = error
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        if let fetchError { throw fetchError }
        return UsageData(
            weeklyUsage: WeeklyUsage(used: 1, total: 10),
            dailyUsage: nil,
            accountMetrics: AccountMetrics(totalTokens: 100, totalActualCost: 1),
            keys: [],
            usageRecords: [],
            capabilities: [.subscriptions, .accountMetrics]
        )
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {}

    func testStation(profile: StationProfile) async throws {
        if let stationError { throw stationError }
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {
        if let fetchError { throw fetchError }
    }

    func testConnection(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> ConnectionTestResult {
        if let fetchError { throw fetchError }
        return ConnectionTestResult(
            capabilities: [.subscriptions, .accountMetrics],
            subscriptions: [],
            checkedAt: Date()
        )
    }

    func invalidateSession() async {}
}

private actor ControlledRefreshUsageClient: UsageFetching {
    private var pending: [UUID: CheckedContinuation<UsageData, any Error>] = [:]
    private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var resetCallCount = 0

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        let waiters = startWaiters.removeValue(forKey: profile.id) ?? []
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[profile.id] = continuation
        }
    }

    func waitUntilStarted(profileID: UUID) async {
        if pending[profileID] != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters[profileID, default: []].append(continuation)
        }
    }

    func complete(profileID: UUID, totalActualCost: Double) {
        guard let continuation = pending.removeValue(forKey: profileID) else { return }
        continuation.resume(returning: UsageData(
            weeklyUsage: nil,
            dailyUsage: nil,
            accountMetrics: AccountMetrics(totalTokens: Int64(totalActualCost), totalActualCost: totalActualCost),
            keys: [],
            usageRecords: [],
            capabilities: [.accountMetrics]
        ))
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {
        resetCallCount += 1
    }

    func testStation(profile: StationProfile) async throws {}
    func testLogin(profile: StationProfile, credentials: Credentials) async throws {}

    func testConnection(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> ConnectionTestResult {
        ConnectionTestResult(capabilities: [], subscriptions: [], checkedAt: Date())
    }

    func invalidateSession() async {}
}

private final class TestLaunchAtLoginManager: LaunchAtLoginManaging {
    private(set) var isEnabled = false

    var statusDescription: String {
        isEnabled ? "开机启动已启用" : "开机启动未启用"
    }

    func setEnabled(_ enabled: Bool, refreshRegistration: Bool) throws {
        isEnabled = enabled
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
