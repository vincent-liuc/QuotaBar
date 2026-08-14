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
        try testReleaseAssetPairing()
        try await testUpdateCheckRetry()
        await testUpdateInstallationGate()
        testAutomaticUpdateTaskGeneration()
        try await testLoginOnlyUsesLoginEndpoint()
        await testLoginFailureClassification()
        try await testStationProbeRecognizesSub2API()
        try await testStationProbePreservesTemporaryFailure()
        await testStationProbeFailureClassification()
        testDashboardIssueClassification()
        try await testUsageStoreOnboardingState()
        try await testSelectingProfileWithoutCredentials()
        try await testBackgroundValidationCannotStealProfileSelection()
        try await testSelectingProfileUnderValidationPreservesTransition()
        try await testLatestProfileSelectionWinsSessionInvalidation()
        try await testUsageStoreLatestRefreshWins()
        try await testSaveConfigurationRefreshesOnce()
        try await testSupersededRefreshDoesNotRepeatSuccessfulReset()
        try await testEndpointChangeCancelsInFlightReset()
        try await testEndpointChangeClearsResetObservation()
        try await testEndpointValidationSuspendsOldRefresh()
        try await testPaginationAndDeduplication()
        try await testAPIKeyQuotaResetRequest()
        try await testOptionalEndpointDegradation()
        testLegacyDefaultsMigration()
        testStatusCatFill()
        testDailyUpdateSchedule()
        testDailyUpdateScheduleAcrossDST()
        testWeeklyResetCalculation()
        testWeeklyResetMonitor()
        await testWeeklyResetClaims()
        testStaleResetClaimCannotAffectNewEndpoint()
        testInitialDashboardPresentationPolicy()
        try testCredentialFileStorage()
        print("Self-test passed: 40 checks")
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
        require(initial.refreshInterval == 60, "refresh interval defaults to one minute")
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
        let leftEar = bitmapImage(StatusRingRenderer.image(progress: 0.5, phase: .ready, tailPhase: .pi * 1.5))
        let rightEar = bitmapImage(StatusRingRenderer.image(progress: 0.5, phase: .ready, tailPhase: .pi * 0.5))
        let split = max(ten.pixelsHigh / 2, 1)
        require(greenPixels(empty, rows: 0..<empty.pixelsHigh) == 0, "zero usage cat remains black")
        require(greenPixels(ten, rows: 0..<ten.pixelsHigh) > 0, "ten percent cat has green fill")
        let tenTop = greenPixels(ten, rows: 0..<split)
        let tenBottom = greenPixels(ten, rows: split..<ten.pixelsHigh)
        require(tenBottom > tenTop, "ten percent green fill stays at cat bottom")
        require(greenPixels(full, rows: 0..<full.pixelsHigh) > greenPixels(ten, rows: 0..<ten.pixelsHigh), "full cat has more green fill")
        require(empty.colorAt(x: 0, y: 0)?.alphaComponent == 0, "status icon has no outer background")
        require(waveA.tiffRepresentation != waveB.tiffRepresentation, "wave phase animates green surface")
        let topEnd = Int(ceil(Double(leftEar.pixelsHigh) * 0.40))
        var changedTopPixels = 0
        for y in 0..<topEnd {
            for x in 0..<leftEar.pixelsWide where pixelsDiffer(leftEar, rightEar, x: x, y: y) {
                changedTopPixels += 1
            }
        }
        require(changedTopPixels >= 8, "left ear swing visibly changes the 20px top silhouette")
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

    private static func testDailyUpdateScheduleAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = ISO8601DateFormatter()

        let beforeSpringTransition = formatter.date(from: "2026-03-07T17:00:00Z")!
        let springNoon = formatter.date(from: "2026-03-08T16:00:00Z")!
        require(
            DailyUpdateSchedule.nextNoon(after: beforeSpringTransition, calendar: calendar) == springNoon,
            "spring DST transition still schedules New York local noon"
        )
        require(
            springNoon.timeIntervalSince(beforeSpringTransition) == 23 * 60 * 60,
            "spring DST schedule follows the local calendar rather than a 24-hour offset"
        )

        let beforeFallTransition = formatter.date(from: "2026-10-31T16:00:00Z")!
        let fallNoon = formatter.date(from: "2026-11-01T17:00:00Z")!
        require(
            DailyUpdateSchedule.nextNoon(after: beforeFallTransition, calendar: calendar) == fallNoon,
            "fall DST transition still schedules New York local noon"
        )
        require(
            fallNoon.timeIntervalSince(beforeFallTransition) == 25 * 60 * 60,
            "fall DST schedule follows the local calendar rather than a 24-hour offset"
        )
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

    private static func testWeeklyResetClaims() async {
        let suiteName = "dev.ruobin.QuotaBar.ResetClaimSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = WeeklyResetMonitor(defaults: defaults)
        let profileID = UUID()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let nextCycle = first.addingTimeInterval(7 * 86_400)

        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: first,
                enabled: true, visibleKeyIDs: [105, 106]
            ).isEmpty,
            "reset claim test establishes baseline"
        )

        let plans = await withTaskGroup(of: [Int].self, returning: [[Int]].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    monitor.resetPlan(
                        profileID: profileID, subscriptionID: 10, resetAt: nextCycle,
                        enabled: true, visibleKeyIDs: [105, 106]
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        require(plans.flatMap { $0 }.sorted() == [105, 106], "concurrent reset plans claim each key once")

        monitor.markKeyHandled(profileID: profileID, keyID: 105)
        monitor.releaseKeyClaims(profileID: profileID, keyIDs: [106])
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: nextCycle,
                enabled: true, visibleKeyIDs: [105, 106]
            ) == [106],
            "released reset claim remains pending for retry"
        )
        require(
            monitor.resetPlan(
                profileID: profileID, subscriptionID: 10, resetAt: nextCycle,
                enabled: true, visibleKeyIDs: [105, 106]
            ).isEmpty,
            "retry claim is not issued twice while in flight"
        )
    }

    private static func testStaleResetClaimCannotAffectNewEndpoint() {
        let suiteName = "dev.ruobin.QuotaBar.StaleResetClaimSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = WeeklyResetMonitor(defaults: defaults)
        let profileID = UUID()
        let oldBaseline = Date(timeIntervalSince1970: 1_800_000_000)
        let oldCycle = oldBaseline.addingTimeInterval(7 * 86_400)

        require(
            monitor.resetClaim(
                profileID: profileID,
                subscriptionID: 10,
                resetAt: oldBaseline,
                enabled: true,
                visibleKeyIDs: [105]
            ).keyIDs.isEmpty,
            "old endpoint reset baseline is established"
        )
        let oldClaim = monitor.resetClaim(
            profileID: profileID,
            subscriptionID: 10,
            resetAt: oldCycle,
            enabled: true,
            visibleKeyIDs: [105]
        )
        require(oldClaim.keyIDs == [105] && oldClaim.token != nil, "old endpoint owns a reset claim")

        monitor.removeObservation(for: profileID)
        let newBaseline = oldCycle.addingTimeInterval(86_400)
        let newCycle = newBaseline.addingTimeInterval(7 * 86_400)
        require(
            monitor.resetClaim(
                profileID: profileID,
                subscriptionID: 20,
                resetAt: newBaseline,
                enabled: true,
                visibleKeyIDs: [105]
            ).keyIDs.isEmpty,
            "new endpoint reset baseline is independent"
        )
        let newClaim = monitor.resetClaim(
            profileID: profileID,
            subscriptionID: 20,
            resetAt: newCycle,
            enabled: true,
            visibleKeyIDs: [105]
        )
        require(newClaim.keyIDs == [105] && newClaim.token != nil, "new endpoint owns its pending reset")
        require(oldClaim.token != newClaim.token, "endpoint replacement rotates the reset claim token")
        require(
            !monitor.markKeyHandled(profileID: profileID, keyID: 105, claimToken: oldClaim.token),
            "stale endpoint completion cannot handle a new pending key"
        )

        monitor.releaseKeyClaims(profileID: profileID, keyIDs: newClaim.keyIDs, claimToken: newClaim.token)
        require(
            monitor.resetClaim(
                profileID: profileID,
                subscriptionID: 20,
                resetAt: newCycle,
                enabled: true,
                visibleKeyIDs: [105]
            ).keyIDs == [105],
            "new endpoint pending key survives stale completion"
        )
    }

    private static func testInitialDashboardPresentationPolicy() {
        let configuredSuite = "dev.ruobin.QuotaBar.InitialDashboard.Configured.\(UUID().uuidString)"
        let configuredDefaults = UserDefaults(suiteName: configuredSuite)!
        defer { configuredDefaults.removePersistentDomain(forName: configuredSuite) }
        require(
            !InitialDashboardPresentationPolicy.shouldPresent(
                needsConfiguration: false,
                defaults: configuredDefaults
            ),
            "configured first launch does not show Dashboard"
        )
        require(
            !InitialDashboardPresentationPolicy.shouldPresent(
                needsConfiguration: true,
                defaults: configuredDefaults
            ),
            "later configuration failure does not auto-open Dashboard"
        )

        let onboardingSuite = "dev.ruobin.QuotaBar.InitialDashboard.Onboarding.\(UUID().uuidString)"
        let onboardingDefaults = UserDefaults(suiteName: onboardingSuite)!
        defer { onboardingDefaults.removePersistentDomain(forName: onboardingSuite) }
        require(
            InitialDashboardPresentationPolicy.shouldPresent(
                needsConfiguration: true,
                defaults: onboardingDefaults
            ),
            "unconfigured first launch shows onboarding once"
        )
        require(
            !InitialDashboardPresentationPolicy.shouldPresent(
                needsConfiguration: true,
                defaults: onboardingDefaults
            ),
            "onboarding does not auto-open twice"
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

    private static func testReleaseAssetPairing() throws {
        func asset(_ name: String, id: Int) -> GitHubRelease.Asset {
            GitHubRelease.Asset(
                name: name,
                url: URL(string: "https://api.github.com/repos/vincent-liuc/QuotaBar/releases/assets/\(id)")!,
                browserDownloadURL: URL(string: "https://example.com/assets/\(id)/\(name)")!
            )
        }

        func release(assets: [GitHubRelease.Asset]) -> GitHubRelease {
            GitHubRelease(
                tagName: "v1.12.0",
                htmlURL: URL(string: "https://github.com/vincent-liuc/QuotaBar/releases/tag/v1.12.0")!,
                assets: assets
            )
        }

        let matchingDMG = asset("QuotaBar-1.12.0-universal.dmg", id: 104)
        let matchingChecksum = asset("QuotaBar-1.12.0-universal.dmg.sha256", id: 105)
        let mixedRelease = release(assets: [
            asset("QuotaBar-1.11.9-universal.dmg", id: 100),
            asset("QuotaBar-1.12.0-arm64.dmg", id: 101),
            asset("QuotaBar-1.11.9-universal.dmg.sha256", id: 102),
            asset("QuotaBar-1.12.0-universal.dmg.sha256.txt", id: 103),
            matchingChecksum,
            matchingDMG
        ])
        guard case .available(let update) = try ReleaseResolver.resolve(
            mixedRelease,
            currentVersion: "1.11.0"
        ) else {
            fatalError("Self-test failed: exact release asset pair is available")
        }
        require(update.fileName == matchingDMG.name, "release resolver selects the exact tag-matched DMG")
        require(update.downloadAPIURL == matchingDMG.url, "release resolver ignores similarly named DMGs")
        require(update.checksumAPIURL == matchingChecksum.url, "release resolver selects the matching DMG checksum")

        do {
            _ = try ReleaseResolver.resolve(
                release(assets: [
                    asset("QuotaBar-1.11.9-universal.dmg", id: 110),
                    asset("QuotaBar-1.12.0-arm64.dmg", id: 111),
                    matchingChecksum
                ]),
                currentVersion: "1.11.0"
            )
            fatalError("Self-test failed: missing exact tag-matched DMG")
        } catch AppUpdaterError.missingDMG {
            // Expected: a checksum or another version's DMG cannot stand in for the exact DMG.
        }

        do {
            _ = try ReleaseResolver.resolve(
                release(assets: [
                    matchingDMG,
                    asset("QuotaBar-1.11.9-universal.dmg.sha256", id: 120),
                    asset("QuotaBar-1.12.0-universal.dmg.sha256.txt", id: 121)
                ]),
                currentVersion: "1.11.0"
            )
            fatalError("Self-test failed: missing checksum paired to the exact DMG")
        } catch AppUpdaterError.missingChecksum {
            // Expected: only the exact DMG filename plus .sha256 is accepted.
        }
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

    private static func testUpdateInstallationGate() async {
        let gate = UpdateInstallationGate()
        require(gate.acquire(), "first update installation acquires gate")

        let contenderResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<16 {
                group.addTask { gate.acquire() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        require(contenderResults.allSatisfy { !$0 }, "concurrent update installations fail fast")

        gate.release()
        require(gate.acquire(), "update installation gate is reusable after release")
        gate.release()
        require(
            AppUpdaterError.updateInProgress.errorDescription == "更新正在进行",
            "concurrent update error is clear"
        )
    }

    private static func testAutomaticUpdateTaskGeneration() {
        var generation = AutomaticUpdateTaskGeneration()
        let oldID = generation.begin()
        generation.cancel()
        let newID = generation.begin()

        require(!generation.finish(oldID), "stale automatic update cannot finish new generation")
        require(generation.isCurrent(newID), "new automatic update survives stale completion")
        require(generation.finish(newID), "current automatic update finishes its own generation")
        require(!generation.isCurrent(newID), "finished automatic update clears its generation")
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

        let discoveryPaths = LockedStrings()
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            discoveryPaths.append(url.path)
            if url.path.hasSuffix("/auth/login") {
                return mockResponse(
                    url: url,
                    json: #"{"code":0,"message":"success","data":{"access_token":"discovery-token"}}"#
                )
            }
            return mockResponse(
                url: url,
                json: #"{"code":0,"message":"success","data":[{"id":7,"name":"Weekly","status":"active","weekly_limit_usd":100}]}"#
            )
        }
        let discoveryClient = APIClient(session: URLSession(configuration: configuration))
        let discovery = try await discoveryClient.discoverAccount(
            profile: StationProfile(name: "Discovery", serviceURL: "https://relay.example.com"),
            credentials: Credentials(email: "test@example.com", password: "test")
        )
        require(
            discoveryPaths.values == ["/api/v1/auth/login", "/api/v1/subscriptions"],
            "account discovery reuses one login for subscriptions"
        )
        require(
            discovery.subscriptions == .available([
                SubscriptionOption(id: 7, name: "Weekly", status: "active", hasWeeklyLimit: true)
            ]),
            "account discovery returns subscription options"
        )

        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            return mockResponse(
                url: url,
                json: #"{"code":0,"message":"success","data":{"requires_2fa":true,"temp_token":"temporary"}}"#
            )
        }
        let twoFactorClient = APIClient(session: URLSession(configuration: configuration))
        do {
            try await twoFactorClient.testLogin(
                profile: StationProfile(name: "2FA", serviceURL: "https://relay.example.com"),
                credentials: Credentials(email: "test@example.com", password: "test")
            )
            fatalError("Self-test failed: two-factor login requires account action")
        } catch APIClientError.twoFactorAuthenticationRequired {
            // Expected: do not misclassify a valid 2FA challenge as a station response error.
        }
    }

    private static func testLoginFailureClassification() async {
        let cases: [(name: String, status: Int, json: String, expected: APIClientError)] = [
            (
                "turnstile",
                400,
                #"{"code":400,"message":"Turnstile verification failed","reason":"TURNSTILE_VERIFICATION_FAILED","data":null}"#,
                .interactiveAuthenticationRequired
            ),
            (
                "backend mode",
                403,
                #"{"code":403,"message":"Admin only","reason":"BACKEND_MODE_ADMIN_ONLY","data":null}"#,
                .backendModeRestricted
            ),
            (
                "invalid credentials",
                401,
                #"{"code":401,"message":"Invalid credentials","reason":"INVALID_CREDENTIALS","data":null}"#,
                .authenticationFailed
            ),
            (
                "invalid credentials reason",
                400,
                #"{"code":400,"message":"Login failed","reason":"INVALID_CREDENTIALS","data":null}"#,
                .authenticationFailed
            )
        ]
        defer { MockURLProtocol.requestHandler = nil }

        for item in cases {
            MockURLProtocol.requestHandler = { request in
                let url = try requireURL(request)
                require(url.path == "/api/v1/auth/login", "login \(item.name) uses login route")
                require(request.httpMethod == "POST", "login \(item.name) uses POST")
                return mockResponse(url: url, json: item.json, status: item.status)
            }
            let client = makeMockAPIClient()
            await requireAPIClientError(item.expected, "login \(item.name)") {
                try await client.testLogin(
                    profile: StationProfile(name: "Login failure", serviceURL: "https://relay.example.com"),
                    credentials: Credentials(email: "test@example.com", password: "wrong")
                )
            }
        }
    }

    private static func testStationProbeRecognizesSub2API() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try requireURL(request)
            require(url.path == "/api/v1/settings/public", "station probe uses public settings route")
            require(request.httpMethod == "GET", "station probe does not submit login data")
            return mockResponse(
                url: url,
                json: #"{"code":0,"message":"success","data":{"version":"1.2.3","site_name":"Relay","server_timezone":"Asia/Shanghai"}}"#
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

    private static func testStationProbeFailureClassification() async {
        let cases: [(name: String, status: Int, json: String, expected: APIClientError)] = [
            (
                "missing route",
                404,
                #"{"code":404,"message":"not found","data":{}}"#,
                .incompatibleStation
            ),
            (
                "missing fingerprint",
                200,
                #"{"code":0,"message":"success","data":{}}"#,
                .incompatibleStation
            ),
            (
                "unauthorized",
                401,
                #"{"code":401,"message":"unauthorized","data":{}}"#,
                .stationProbeRejected(401)
            ),
            (
                "forbidden",
                403,
                #"{"code":403,"message":"forbidden","data":{}}"#,
                .stationProbeRejected(403)
            )
        ]
        defer { MockURLProtocol.requestHandler = nil }

        for item in cases {
            MockURLProtocol.requestHandler = { request in
                let url = try requireURL(request)
                require(url.path == "/api/v1/settings/public", "station \(item.name) uses public route")
                require(request.httpMethod == "GET", "station \(item.name) uses GET")
                return mockResponse(url: url, json: item.json, status: item.status)
            }
            let client = makeMockAPIClient()
            await requireAPIClientError(item.expected, "station \(item.name)") {
                try await client.testStation(
                    profile: StationProfile(name: "Probe", serviceURL: "https://relay.example.com")
                )
            }
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
        let stationTestCallCount = await client.stationTestCallCount
        let loginTestCallCount = await client.loginTestCallCount
        require(stationTestCallCount == 1, "station validation calls only the unauthenticated station probe")
        require(loginTestCallCount == 0, "station validation does not call the login endpoint")
        require(store.credentials(for: initialProfile.id) == nil, "station validation does not require stored credentials")
        require(store.configurationProgress == ConfigurationProgress(stationIsValid: true, accountIsValid: false), "station validation completes first step")

        let credentials = Credentials(email: "test@example.com", password: "password")
        let accountResult = try await store.testLogin(profile: initialProfile, credentials: credentials)
        require(store.configurationProgress.isComplete, "account discovery validates the second onboarding step")
        require(
            accountResult.subscriptions == .available([
                SubscriptionOption(id: 7, name: "Weekly", status: "active", hasWeeklyLimit: true)
            ]),
            "account discovery returns subscriptions to settings"
        )
        require(store.subscriptionOptions(for: initialProfile.id)?.count == 1, "account subscriptions are cached per profile")

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
    private static func testSelectingProfileWithoutCredentials() async throws {
        let suiteName = "dev.ruobin.QuotaBar.UnconfiguredProfileSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-UnconfiguredProfileSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let configured = StationProfile(
            name: "Configured",
            serviceURL: "https://configured.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let unconfigured = StationProfile(
            name: "Unconfigured",
            serviceURL: "https://unconfigured.example.com",
            lastCheckedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(
            profiles: [configured, unconfigured],
            activeProfileID: configured.id
        ))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: configured.id)
        let client = OnboardingUsageClient()
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )

        try await store.selectProfile(unconfigured.id)
        require(store.activeProfileID == unconfigured.id, "unconfigured profile becomes active")
        require(profileStore.load().activeProfileID == unconfigured.id, "unconfigured profile selection persists")
        require(store.phase == .needsConfiguration, "unconfigured profile opens onboarding")
        require(
            store.configurationProgress == ConfigurationProgress(stationIsValid: true, accountIsValid: false),
            "unconfigured profile preserves completed station step"
        )
        let fetchesBeforeCredentials = await client.fetchCallCount
        require(fetchesBeforeCredentials == 0, "unconfigured profile does not fetch with missing credentials")

        try await store.updateCredentials(credentials, for: unconfigured.id)
        try await waitUntil { store.phase == .ready }
        require(store.activeProfileID == unconfigured.id, "credential save keeps selected profile active")
        let fetchesAfterCredentials = await client.fetchCallCount
        require(fetchesAfterCredentials == 1, "credential save refreshes only the selected profile")
    }

    @MainActor
    private static func testBackgroundValidationCannotStealProfileSelection() async throws {
        let suiteName = "dev.ruobin.QuotaBar.BackgroundValidationSelectionSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-BackgroundValidationSelectionSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let active = StationProfile(
            name: "A",
            serviceURL: "https://a.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let validating = StationProfile(
            name: "B",
            serviceURL: "https://b.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let selected = StationProfile(
            name: "C",
            serviceURL: "https://c.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(
            profiles: [active, validating, selected],
            activeProfileID: active.id
        ))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: selected.id)
        let client = ControlledProfileValidationUsageClient(blockedProfileID: validating.id)
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )

        var candidate = validating
        candidate.serviceURL = "https://b-new.example.com"
        let validation = Task { try await store.updateStationProfile(candidate) }
        await client.waitUntilStationValidationStarted()

        try await store.selectProfile(selected.id)
        require(store.activeProfileID == selected.id, "A to C selection completes during B validation")
        require(store.phase == .ready, "selected C profile loads during B validation")

        await client.completeStationValidation()
        do {
            try await validation.value
            fatalError("Self-test failed: stale B validation should be cancelled")
        } catch is CancellationError {
            // Expected: validating an inactive profile cannot override a later user selection.
        }

        require(store.activeProfileID == selected.id, "stale B validation cannot steal selection from C")
        let persisted = profileStore.load()
        require(persisted.activeProfileID == selected.id, "C remains the persisted active profile")
        require(
            persisted.profiles.first(where: { $0.id == validating.id })?.serviceURL == validating.serviceURL,
            "stale B endpoint is not persisted after A to C selection"
        )
        let fetchedProfileIDs = await client.fetchedProfileIDs
        require(fetchedProfileIDs == [selected.id], "stale B validation never fetches usage")
    }

    @MainActor
    private static func testSelectingProfileUnderValidationPreservesTransition() async throws {
        let suiteName = "dev.ruobin.QuotaBar.SelectValidatingProfileSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-SelectValidatingProfileSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let active = StationProfile(
            name: "A",
            serviceURL: "https://a.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let validating = StationProfile(
            name: "B",
            serviceURL: "https://b.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(
            profiles: [active, validating],
            activeProfileID: active.id
        ))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: validating.id)
        let client = ControlledProfileValidationUsageClient(blockedProfileID: validating.id)
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )

        var candidate = validating
        candidate.serviceURL = "https://b-new.example.com"
        let validation = Task { try await store.updateStationProfile(candidate) }
        await client.waitUntilStationValidationStarted()

        try await store.selectProfile(validating.id)
        let fetchesBeforeValidation = await client.fetchedProfileIDs
        require(fetchesBeforeValidation.isEmpty, "B selection remains suspended behind its endpoint transition")
        require(store.phase == .loading, "selected B remains loading while validation is in flight")

        await client.completeStationValidation()
        try await validation.value
        try await waitUntil { store.phase == .ready }

        require(store.activeProfileID == validating.id, "selected B remains active after validation")
        require(store.activeProfile?.serviceURL == candidate.serviceURL, "selected B adopts the validated endpoint")
        require(
            profileStore.load().profiles.first(where: { $0.id == validating.id })?.serviceURL == candidate.serviceURL,
            "validated B endpoint is persisted"
        )
        let fetchedServiceURLs = await client.fetchedServiceURLs
        require(
            fetchedServiceURLs == [candidate.serviceURL],
            "B loads only after transition completion and uses the validated endpoint"
        )
    }

    @MainActor
    private static func testLatestProfileSelectionWinsSessionInvalidation() async throws {
        let suiteName = "dev.ruobin.QuotaBar.ProfileSelectionRaceSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-ProfileSelectionRaceSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let first = StationProfile(
            name: "First",
            serviceURL: "https://first.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let second = StationProfile(
            name: "Second",
            serviceURL: "https://second.example.com",
            lastCheckedAt: validatedAt
        )
        let third = StationProfile(
            name: "Third",
            serviceURL: "https://third.example.com",
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(
            profiles: [first, second, third],
            activeProfileID: first.id
        ))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        try credentialStore.save(
            Credentials(email: "test@example.com", password: "password"),
            for: third.id
        )
        let client = ReorderedInvalidationUsageClient()
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )

        let firstSelection = Task { try await store.selectProfile(second.id) }
        await client.waitUntilInvalidationStarted(call: 1)
        let latestSelection = Task { try await store.selectProfile(third.id) }
        await client.waitUntilInvalidationStarted(call: 2)

        await client.completeInvalidation(call: 2)
        try await latestSelection.value
        require(store.activeProfileID == third.id, "latest profile selection becomes active")
        require(store.phase == .ready, "latest profile selection publishes its ready state")
        require(
            store.snapshot?.accountMetrics?.totalActualCost == 3,
            "latest profile selection publishes its own snapshot"
        )

        await client.completeInvalidation(call: 1)
        try await firstSelection.value
        require(store.activeProfileID == third.id, "late invalidation cannot restore an older selection")
        require(profileStore.load().activeProfileID == third.id, "latest profile selection remains persisted")
        require(store.phase == .ready, "late invalidation cannot replace the latest phase")
        require(
            store.snapshot?.accountMetrics?.totalActualCost == 3,
            "late invalidation cannot replace the latest snapshot"
        )
        let fetchedProfileIDs = await client.fetchedProfileIDs
        require(fetchedProfileIDs == [third.id], "only the latest profile fetches after reordered invalidations")
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
    private static func testSaveConfigurationRefreshesOnce() async throws {
        let suiteName = "dev.ruobin.QuotaBar.ConfigurationRefreshSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-ConfigurationRefreshSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let profile = StationProfile(name: "Configured", serviceURL: "https://configured.example.com")
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(profiles: [profile], activeProfileID: profile.id))
        let client = OnboardingUsageClient()
        let store = UsageStore(
            client: client,
            credentialStore: CredentialStore(baseDirectory: baseDirectory),
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: WeeklyResetMonitor(defaults: defaults),
            startsPolling: false
        )
        let credentials = Credentials(email: "test@example.com", password: "password")

        try await store.saveConfiguration(
            profile: profile,
            credentials: credentials,
            refreshInterval: 60,
            launchAtLogin: false,
            showAPIKeyDetails: true,
            showMetricCards: true,
            showUsageHistory: true,
            automaticallyUpdates: false
        )
        try await Task.sleep(for: .milliseconds(50))
        let fetchCallCount = await client.fetchCallCount
        require(fetchCallCount == 1, "configuration save performs exactly one immediate usage refresh")
        require(store.phase == .ready, "configuration save awaits its immediate refresh")
    }

    @MainActor
    private static func testSupersededRefreshDoesNotRepeatSuccessfulReset() async throws {
        let suiteName = "dev.ruobin.QuotaBar.ResetSupersedeSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-ResetSupersedeSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousResetAt = validatedAt.addingTimeInterval(7 * 86_400)
        let currentResetAt = previousResetAt.addingTimeInterval(7 * 86_400)
        let profile = StationProfile(
            name: "Reset Race",
            serviceURL: "https://reset-race.example.com",
            automaticallyResetsAPIKeyQuota: true,
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(profiles: [profile], activeProfileID: profile.id))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        try credentialStore.save(
            Credentials(email: "test@example.com", password: "password"),
            for: profile.id
        )
        let resetMonitor = WeeklyResetMonitor(defaults: defaults)
        require(
            resetMonitor.resetPlan(
                profileID: profile.id,
                subscriptionID: 10,
                resetAt: previousResetAt,
                enabled: true,
                visibleKeyIDs: [105]
            ).isEmpty,
            "superseded reset test establishes baseline"
        )

        let client = SupersededResetUsageClient(resetAt: currentResetAt)
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: resetMonitor,
            startsPolling: false
        )

        let resettingRefresh = Task { await store.refresh() }
        await client.waitUntilFirstResetStarted()
        let initialResetCallCount = await client.resetCallCount
        require(initialResetCallCount == 1, "first refresh starts one quota reset")

        let supersedingRefresh = Task { await store.refresh() }
        await supersedingRefresh.value
        require(store.phase == .ready, "superseding refresh completes while reset is in flight")

        await client.completeFirstReset()
        await resettingRefresh.value
        await store.refresh()
        let finalResetCallCount = await client.resetCallCount
        require(
            finalResetCallCount == 1,
            "successful reset is not repeated after its refresh is superseded"
        )
    }

    @MainActor
    private static func testEndpointChangeCancelsInFlightReset() async throws {
        let suiteName = "dev.ruobin.QuotaBar.EndpointResetCancellationSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-EndpointResetCancellationSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousResetAt = validatedAt.addingTimeInterval(7 * 86_400)
        let currentResetAt = previousResetAt.addingTimeInterval(7 * 86_400)
        let profile = StationProfile(
            name: "Old endpoint",
            serviceURL: "https://old-reset.example.com",
            automaticallyResetsAPIKeyQuota: true,
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(profiles: [profile], activeProfileID: profile.id))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: profile.id)
        let monitor = WeeklyResetMonitor(defaults: defaults)
        require(
            monitor.resetPlan(
                profileID: profile.id,
                subscriptionID: 10,
                resetAt: previousResetAt,
                enabled: true,
                visibleKeyIDs: [105]
            ).isEmpty,
            "reset cancellation test establishes baseline"
        )
        let client = CancellationAwareResetUsageClient(
            oldServiceURL: profile.serviceURL,
            resetAt: currentResetAt
        )
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: monitor,
            startsPolling: false
        )

        let oldRefresh = Task { await store.refresh() }
        await client.waitUntilResetStarted()

        var candidate = profile
        candidate.serviceURL = "https://new-reset.example.com"
        try await store.updateStationProfile(candidate)
        await client.waitUntilResetCancelled()
        await oldRefresh.value
        try await waitUntil { store.phase == .ready }

        require(store.activeProfile?.serviceURL == candidate.serviceURL, "endpoint change activates the new station")
        let resetCallCount = await client.resetCallCount
        let resetCompletionCount = await client.resetCompletionCount
        require(resetCallCount == 1, "endpoint change does not start another old quota reset")
        require(resetCompletionCount == 0, "endpoint change cancels the in-flight quota reset")
        let fetchedServiceURLs = await client.fetchedServiceURLs
        require(
            fetchedServiceURLs == [profile.serviceURL, candidate.serviceURL],
            "post-cancellation refresh fetches only the new endpoint"
        )
    }

    @MainActor
    private static func testEndpointChangeClearsResetObservation() async throws {
        let suiteName = "dev.ruobin.QuotaBar.EndpointResetSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-EndpointResetSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = StationProfile(
            name: "Old station",
            serviceURL: "https://old.example.com",
            automaticallyResetsAPIKeyQuota: true,
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(profiles: [profile], activeProfileID: profile.id))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: profile.id)
        let monitor = WeeklyResetMonitor(defaults: defaults)
        var resetAt = validatedAt.addingTimeInterval(7 * 86_400)
        let client = EndpointChangeUsageClient(resetAt: resetAt)
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: monitor,
            startsPolling: false
        )

        func seedPendingReset(previousResetAt: Date, nextResetAt: Date) {
            require(
                monitor.resetPlan(
                    profileID: profile.id, subscriptionID: 10, resetAt: previousResetAt,
                    enabled: true, visibleKeyIDs: [105]
                ).isEmpty,
                "endpoint reset test establishes old-station baseline"
            )
            require(
                monitor.resetPlan(
                    profileID: profile.id, subscriptionID: 10, resetAt: nextResetAt,
                    enabled: true, visibleKeyIDs: [105]
                ) == [105],
                "old endpoint has pending reset work"
            )
            monitor.releaseKeyClaims(profileID: profile.id, keyIDs: [105])
        }

        seedPendingReset(previousResetAt: validatedAt, nextResetAt: resetAt)
        var changedProfile = store.activeProfile!
        changedProfile.serviceURL = "https://connection.example.com"
        _ = try await store.testConnection(profile: changedProfile, credentials: credentials)
        try await waitUntil { store.phase == .ready }

        var resetCallCount = await client.resetCallCount
        require(resetCallCount == 0, "testConnection endpoint change does not PUT old reset work")

        let previousResetAt = resetAt
        resetAt = resetAt.addingTimeInterval(7 * 86_400)
        await client.setResetAt(resetAt)
        seedPendingReset(previousResetAt: previousResetAt, nextResetAt: resetAt)
        changedProfile = store.activeProfile!
        changedProfile.apiPath = "/gateway/v1"
        _ = try await store.testLogin(profile: changedProfile, credentials: credentials)
        try await waitUntil { store.phase == .ready }
        resetCallCount = await client.resetCallCount
        require(resetCallCount == 0, "testLogin endpoint change does not PUT old reset work")

        let stationPreviousResetAt = resetAt
        resetAt = resetAt.addingTimeInterval(7 * 86_400)
        await client.setResetAt(resetAt)
        seedPendingReset(previousResetAt: stationPreviousResetAt, nextResetAt: resetAt)
        changedProfile = store.activeProfile!
        changedProfile.timezone = "UTC"
        try await store.updateStationProfile(changedProfile)
        try await waitUntil { store.phase == .ready }
        resetCallCount = await client.resetCallCount
        require(resetCallCount == 0, "updateStationProfile endpoint change does not PUT old reset work")

        let profilePreviousResetAt = resetAt
        resetAt = resetAt.addingTimeInterval(7 * 86_400)
        await client.setResetAt(resetAt)
        seedPendingReset(previousResetAt: profilePreviousResetAt, nextResetAt: resetAt)
        changedProfile = store.activeProfile!
        changedProfile.serviceURL = "https://profile-save.example.com"
        try await store.updateProfile(changedProfile, credentials: credentials)
        try await waitUntil { store.phase == .ready }
        resetCallCount = await client.resetCallCount
        require(resetCallCount == 0, "saveProfile endpoint change does not PUT old reset work")

        let configurationPreviousResetAt = resetAt
        resetAt = resetAt.addingTimeInterval(7 * 86_400)
        await client.setResetAt(resetAt)
        seedPendingReset(previousResetAt: configurationPreviousResetAt, nextResetAt: resetAt)
        changedProfile = store.activeProfile!
        changedProfile.apiPath = "/api/v2"
        try await store.saveConfiguration(
            profile: changedProfile,
            credentials: credentials,
            refreshInterval: store.preferences.refreshInterval,
            launchAtLogin: store.preferences.launchAtLogin,
            showAPIKeyDetails: store.preferences.showAPIKeyDetails,
            showMetricCards: store.preferences.showMetricCards,
            showUsageHistory: store.preferences.showUsageHistory,
            automaticallyUpdates: store.preferences.automaticallyUpdates
        )
        resetCallCount = await client.resetCallCount
        require(resetCallCount == 0, "saveConfiguration endpoint change does not PUT old reset work")
    }

    @MainActor
    private static func testEndpointValidationSuspendsOldRefresh() async throws {
        let suiteName = "dev.ruobin.QuotaBar.EndpointTransitionSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "QuotaBar-EndpointTransitionSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let validatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousResetAt = validatedAt.addingTimeInterval(7 * 86_400)
        let nextResetAt = previousResetAt.addingTimeInterval(7 * 86_400)
        let profile = StationProfile(
            name: "Old station",
            serviceURL: "https://old-transition.example.com",
            automaticallyResetsAPIKeyQuota: true,
            lastCheckedAt: validatedAt,
            lastAuthenticatedAt: validatedAt
        )
        let profileStore = StationProfileStore(defaults: defaults)
        try profileStore.save(StationProfilesState(profiles: [profile], activeProfileID: profile.id))
        let credentialStore = CredentialStore(baseDirectory: baseDirectory)
        let credentials = Credentials(email: "test@example.com", password: "password")
        try credentialStore.save(credentials, for: profile.id)
        let monitor = WeeklyResetMonitor(defaults: defaults)
        require(
            monitor.resetPlan(
                profileID: profile.id,
                subscriptionID: 10,
                resetAt: previousResetAt,
                enabled: true,
                visibleKeyIDs: [105]
            ).isEmpty,
            "endpoint transition test establishes reset baseline"
        )

        let client = EndpointTransitionRaceUsageClient(resetAt: nextResetAt)
        let store = UsageStore(
            client: client,
            credentialStore: credentialStore,
            profileStore: profileStore,
            preferencesStore: PreferencesStore(defaults: defaults),
            launchAtLoginManager: TestLaunchAtLoginManager(),
            weeklyResetMonitor: monitor,
            startsPolling: false
        )

        let oldRefresh = Task { await store.refresh() }
        await client.waitUntilFirstFetchStarted()

        var candidate = profile
        candidate.serviceURL = "https://new-transition.example.com"
        let validation = Task { try await store.updateStationProfile(candidate) }
        await client.waitUntilStationProbeStarted()

        require(store.activeProfile?.serviceURL == profile.serviceURL, "unverified endpoint remains memory-only")
        require(profileStore.load().profiles.first?.serviceURL == profile.serviceURL, "unverified endpoint is not persisted")
        await store.refresh()
        let fetchesDuringValidation = await client.fetchCallCount
        require(fetchesDuringValidation == 1, "endpoint validation suppresses new old-station refreshes")

        await client.completeFirstFetch()
        await oldRefresh.value
        let resetsDuringValidation = await client.resetCallCount
        require(resetsDuringValidation == 0, "late old-station fetch cannot trigger quota reset")

        await client.completeStationProbe()
        try await validation.value
        try await waitUntil { store.phase == .ready }
        require(store.activeProfile?.serviceURL == candidate.serviceURL, "validated endpoint becomes active")
        require(profileStore.load().profiles.first?.serviceURL == candidate.serviceURL, "validated endpoint persists")
        let fetchedURLs = await client.fetchedServiceURLs
        require(
            fetchedURLs == [profile.serviceURL, candidate.serviceURL],
            "post-validation refresh uses only the validated endpoint"
        )
        let finalResetCount = await client.resetCallCount
        require(finalResetCount == 0, "endpoint transition never carries reset work to the new station")
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
        let twoFactor = DashboardIssue.classify(APIClientError.twoFactorAuthenticationRequired)
        require(twoFactor.kind == .authentication && twoFactor.settingsTab == .account, "2FA opens account recovery")
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

    private static func makeMockAPIClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(session: URLSession(configuration: configuration))
    }

    private static func requireAPIClientError(
        _ expected: APIClientError,
        _ name: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            fatalError("Self-test failed: \(name) did not throw")
        } catch let error as APIClientError {
            require(error == expected, "\(name) error classification")
        } catch {
            fatalError("Self-test failed: \(name) threw \(error)")
        }
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

private actor ControlledRefreshUsageClient: UsageFetching {
    private var startedProfileIDs: Set<UUID> = []
    private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var completions: [UUID: CheckedContinuation<UsageData, any Error>] = [:]
    private(set) var resetCallCount = 0

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        startedProfileIDs.insert(profile.id)
        startWaiters.removeValue(forKey: profile.id)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            completions[profile.id] = continuation
        }
    }

    func waitUntilStarted(profileID: UUID) async {
        guard !startedProfileIDs.contains(profileID) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[profileID, default: []].append(continuation)
        }
    }

    func complete(profileID: UUID, totalActualCost: Double) {
        guard let continuation = completions.removeValue(forKey: profileID) else {
            fatalError("Self-test failed: missing controlled refresh continuation")
        }
        continuation.resume(returning: UsageData(
            weeklyUsage: nil,
            accountMetrics: AccountMetrics(totalTokens: 100, totalActualCost: totalActualCost),
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

private actor ControlledProfileValidationUsageClient: UsageFetching {
    private let blockedProfileID: UUID
    private var stationValidationContinuation: CheckedContinuation<Void, Never>?
    private var stationValidationStarted = false
    private var stationValidationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchedProfileIDs: [UUID] = []
    private(set) var fetchedServiceURLs: [String] = []

    init(blockedProfileID: UUID) {
        self.blockedProfileID = blockedProfileID
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        fetchedProfileIDs.append(profile.id)
        fetchedServiceURLs.append(profile.serviceURL)
        return UsageData(
            weeklyUsage: nil,
            accountMetrics: AccountMetrics(totalTokens: 400, totalActualCost: 4),
            keys: [],
            usageRecords: [],
            capabilities: [.accountMetrics]
        )
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {}

    func testStation(profile: StationProfile) async throws {
        guard profile.id == blockedProfileID else { return }
        await withCheckedContinuation { continuation in
            stationValidationContinuation = continuation
            stationValidationStarted = true
            stationValidationWaiters.forEach { $0.resume() }
            stationValidationWaiters.removeAll()
        }
    }

    func waitUntilStationValidationStarted() async {
        guard !stationValidationStarted else { return }
        await withCheckedContinuation { continuation in
            stationValidationWaiters.append(continuation)
        }
    }

    func completeStationValidation() {
        guard let continuation = stationValidationContinuation else {
            fatalError("Self-test failed: missing station validation continuation")
        }
        stationValidationContinuation = nil
        continuation.resume()
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {}

    func testConnection(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> ConnectionTestResult {
        ConnectionTestResult(capabilities: [.accountMetrics], subscriptions: [], checkedAt: Date())
    }

    func invalidateSession() async {}
}

private actor ReorderedInvalidationUsageClient: UsageFetching {
    private var invalidationCallCount = 0
    private var invalidationContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedInvalidationCalls: Set<Int> = []
    private var invalidationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var fetchedProfileIDs: [UUID] = []

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        fetchedProfileIDs.append(profile.id)
        return UsageData(
            weeklyUsage: nil,
            accountMetrics: AccountMetrics(totalTokens: 300, totalActualCost: 3),
            keys: [],
            usageRecords: [],
            capabilities: [.accountMetrics]
        )
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {}

    func testStation(profile: StationProfile) async throws {}
    func testLogin(profile: StationProfile, credentials: Credentials) async throws {}

    func testConnection(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> ConnectionTestResult {
        ConnectionTestResult(capabilities: [.accountMetrics], subscriptions: [], checkedAt: Date())
    }

    func invalidateSession() async {
        invalidationCallCount += 1
        let call = invalidationCallCount
        await withCheckedContinuation { continuation in
            invalidationContinuations[call] = continuation
            startedInvalidationCalls.insert(call)
            invalidationWaiters.removeValue(forKey: call)?.forEach { $0.resume() }
        }
    }

    func waitUntilInvalidationStarted(call: Int) async {
        guard !startedInvalidationCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            invalidationWaiters[call, default: []].append(continuation)
        }
    }

    func completeInvalidation(call: Int) {
        guard let continuation = invalidationContinuations.removeValue(forKey: call) else {
            fatalError("Self-test failed: missing invalidation continuation \(call)")
        }
        continuation.resume()
    }
}

private actor SupersededResetUsageClient: UsageFetching {
    private let resetAt: Date
    private var firstResetContinuation: CheckedContinuation<Void, Never>?
    private var firstResetStarted = false
    private var firstResetStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resetCallCount = 0

    init(resetAt: Date) {
        self.resetAt = resetAt
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        UsageData(
            weeklyUsage: WeeklyUsage(subscriptionID: 10, used: 1, total: 10, resetAt: resetAt),
            accountMetrics: nil,
            keys: [UsageKey(
                id: 105,
                name: "Reset Key",
                status: "active",
                quota: 100,
                quotaUsed: 10,
                updatedAt: nil
            )],
            usageRecords: [],
            capabilities: [.subscriptions]
        )
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {
        resetCallCount += 1
        guard resetCallCount == 1 else { return }
        firstResetStarted = true
        firstResetStartWaiters.forEach { $0.resume() }
        firstResetStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstResetContinuation = continuation
        }
    }

    func waitUntilFirstResetStarted() async {
        guard !firstResetStarted else { return }
        await withCheckedContinuation { continuation in
            firstResetStartWaiters.append(continuation)
        }
    }

    func completeFirstReset() {
        firstResetContinuation?.resume()
        firstResetContinuation = nil
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

private actor CancellationAwareResetUsageClient: UsageFetching {
    private let oldServiceURL: String
    private let resetAt: Date
    private var resetStarted = false
    private var resetCancelled = false
    private var resetStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var resetCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resetCallCount = 0
    private(set) var resetCompletionCount = 0
    private(set) var fetchedServiceURLs: [String] = []

    init(oldServiceURL: String, resetAt: Date) {
        self.oldServiceURL = oldServiceURL
        self.resetAt = resetAt
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        fetchedServiceURLs.append(profile.serviceURL)
        guard profile.serviceURL == oldServiceURL else {
            return UsageData(
                weeklyUsage: nil,
                accountMetrics: AccountMetrics(totalTokens: 200, totalActualCost: 2),
                keys: [],
                usageRecords: [],
                capabilities: [.accountMetrics]
            )
        }
        return UsageData(
            weeklyUsage: WeeklyUsage(subscriptionID: 10, used: 1, total: 10, resetAt: resetAt),
            accountMetrics: nil,
            keys: [UsageKey(
                id: 105,
                name: "Cancelling Key",
                status: "active",
                quota: 100,
                quotaUsed: 10,
                updatedAt: nil
            )],
            usageRecords: [],
            capabilities: [.subscriptions]
        )
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {
        resetCallCount += 1
        resetStarted = true
        resetStartWaiters.forEach { $0.resume() }
        resetStartWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(30))
            resetCompletionCount += 1
        } catch is CancellationError {
            resetCancelled = true
            resetCancellationWaiters.forEach { $0.resume() }
            resetCancellationWaiters.removeAll()
            throw CancellationError()
        }
    }

    func waitUntilResetStarted() async {
        guard !resetStarted else { return }
        await withCheckedContinuation { continuation in
            resetStartWaiters.append(continuation)
        }
    }

    func waitUntilResetCancelled() async {
        guard !resetCancelled else { return }
        await withCheckedContinuation { continuation in
            resetCancellationWaiters.append(continuation)
        }
    }

    func testStation(profile: StationProfile) async throws {}
    func testLogin(profile: StationProfile, credentials: Credentials) async throws {}

    func testConnection(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> ConnectionTestResult {
        ConnectionTestResult(capabilities: [.accountMetrics], subscriptions: [], checkedAt: Date())
    }

    func invalidateSession() async {}
}

private actor EndpointChangeUsageClient: UsageFetching {
    private var resetAt: Date
    private(set) var resetCallCount = 0

    init(resetAt: Date) {
        self.resetAt = resetAt
    }

    func setResetAt(_ resetAt: Date) {
        self.resetAt = resetAt
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        UsageData(
            weeklyUsage: WeeklyUsage(subscriptionID: 10, used: 1, total: 10, resetAt: resetAt),
            accountMetrics: nil,
            keys: [UsageKey(
                id: 105,
                name: "Endpoint Key",
                status: "active",
                quota: 100,
                quotaUsed: 10,
                updatedAt: nil
            )],
            usageRecords: [],
            capabilities: [.subscriptions]
        )
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
        ConnectionTestResult(capabilities: [.subscriptions], subscriptions: [], checkedAt: Date())
    }

    func invalidateSession() async {}
}

private actor EndpointTransitionRaceUsageClient: UsageFetching {
    private let resetAt: Date
    private var firstFetchContinuation: CheckedContinuation<UsageData, Never>?
    private var firstFetchStarted = false
    private var firstFetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var stationProbeContinuation: CheckedContinuation<Void, Never>?
    private var stationProbeStarted = false
    private var stationProbeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var fetchedServiceURLs: [String] = []

    init(resetAt: Date) {
        self.resetAt = resetAt
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        fetchCallCount += 1
        fetchedServiceURLs.append(profile.serviceURL)
        if fetchCallCount == 1 {
            firstFetchStarted = true
            firstFetchWaiters.forEach { $0.resume() }
            firstFetchWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                firstFetchContinuation = continuation
            }
        }
        return UsageData(
            weeklyUsage: nil,
            accountMetrics: AccountMetrics(totalTokens: 200, totalActualCost: 2),
            keys: [],
            usageRecords: [],
            capabilities: [.accountMetrics]
        )
    }

    func waitUntilFirstFetchStarted() async {
        guard !firstFetchStarted else { return }
        await withCheckedContinuation { continuation in
            firstFetchWaiters.append(continuation)
        }
    }

    func completeFirstFetch() {
        firstFetchContinuation?.resume(returning: UsageData(
            weeklyUsage: WeeklyUsage(subscriptionID: 10, used: 1, total: 10, resetAt: resetAt),
            accountMetrics: nil,
            keys: [UsageKey(
                id: 105,
                name: "Old Endpoint Key",
                status: "active",
                quota: 100,
                quotaUsed: 10,
                updatedAt: nil
            )],
            usageRecords: [],
            capabilities: [.subscriptions]
        ))
        firstFetchContinuation = nil
    }

    func resetAPIKeyQuota(
        profile: StationProfile,
        credentials: Credentials,
        keyID: Int
    ) async throws {
        resetCallCount += 1
    }

    func testStation(profile: StationProfile) async throws {
        stationProbeStarted = true
        stationProbeWaiters.forEach { $0.resume() }
        stationProbeWaiters.removeAll()
        await withCheckedContinuation { continuation in
            stationProbeContinuation = continuation
        }
    }

    func waitUntilStationProbeStarted() async {
        guard !stationProbeStarted else { return }
        await withCheckedContinuation { continuation in
            stationProbeWaiters.append(continuation)
        }
    }

    func completeStationProbe() {
        stationProbeContinuation?.resume()
        stationProbeContinuation = nil
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {}

    func testConnection(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> ConnectionTestResult {
        ConnectionTestResult(capabilities: [], subscriptions: [], checkedAt: Date())
    }

    func invalidateSession() async {}
}

private actor OnboardingUsageClient: UsageFetching {
    private var fetchError: APIClientError?
    private var stationError: APIClientError?
    private(set) var stationTestCallCount = 0
    private(set) var loginTestCallCount = 0
    private(set) var fetchCallCount = 0

    func setFetchError(_ error: APIClientError?) {
        fetchError = error
    }

    func setStationError(_ error: APIClientError?) {
        stationError = error
    }

    func fetchUsage(profile: StationProfile, credentials: Credentials) async throws -> UsageData {
        fetchCallCount += 1
        if let fetchError { throw fetchError }
        return UsageData(
            weeklyUsage: WeeklyUsage(used: 1, total: 10),
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
        stationTestCallCount += 1
        if let stationError { throw stationError }
    }

    func testLogin(profile: StationProfile, credentials: Credentials) async throws {
        loginTestCallCount += 1
        if let fetchError { throw fetchError }
    }

    func discoverAccount(
        profile: StationProfile,
        credentials: Credentials
    ) async throws -> AccountDiscoveryResult {
        try await testLogin(profile: profile, credentials: credentials)
        return AccountDiscoveryResult(subscriptions: .available([
            SubscriptionOption(id: 7, name: "Weekly", status: "active", hasWeeklyLimit: true)
        ]))
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
