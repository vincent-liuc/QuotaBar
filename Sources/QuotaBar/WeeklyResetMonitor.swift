import Foundation

struct WeeklyResetObservation: Codable, Equatable, Sendable {
    let subscriptionID: Int?
    let resetAt: Date
    var pendingKeyIDs: [Int]

    init(subscriptionID: Int?, resetAt: Date, pendingKeyIDs: [Int] = []) {
        self.subscriptionID = subscriptionID
        self.resetAt = resetAt
        self.pendingKeyIDs = pendingKeyIDs
    }
}

struct WeeklyResetClaim: Equatable, Sendable {
    let token: UUID?
    let keyIDs: [Int]
}

final class WeeklyResetMonitor: @unchecked Sendable {
    static let minimumForwardJump: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let key = "weeklyResetObservations.v1"
    private let lock = NSLock()
    private var claimedKeyIDs: [String: Set<Int>] = [:]
    private var claimTokens: [String: UUID] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resetPlan(
        profileID: UUID,
        subscriptionID: Int?,
        resetAt: Date?,
        enabled: Bool,
        visibleKeyIDs: [Int]
    ) -> [Int] {
        resetClaim(
            profileID: profileID,
            subscriptionID: subscriptionID,
            resetAt: resetAt,
            enabled: enabled,
            visibleKeyIDs: visibleKeyIDs
        ).keyIDs
    }

    func resetClaim(
        profileID: UUID,
        subscriptionID: Int?,
        resetAt: Date?,
        enabled: Bool,
        visibleKeyIDs: [Int]
    ) -> WeeklyResetClaim {
        lock.withLock {
            let keyIDs = resetPlanLocked(
                profileID: profileID,
                subscriptionID: subscriptionID,
                resetAt: resetAt,
                enabled: enabled,
                visibleKeyIDs: visibleKeyIDs
            )
            return WeeklyResetClaim(
                token: keyIDs.isEmpty ? nil : claimTokens[profileID.uuidString],
                keyIDs: keyIDs
            )
        }
    }

    private func resetPlanLocked(
        profileID: UUID,
        subscriptionID: Int?,
        resetAt: Date?,
        enabled: Bool,
        visibleKeyIDs: [Int]
    ) -> [Int] {
        let profileKey = profileID.uuidString
        guard enabled else {
            removeObservationLocked(for: profileID)
            return []
        }
        guard let resetAt else { return [] }
        let current = WeeklyResetObservation(subscriptionID: subscriptionID, resetAt: resetAt)
        guard let previous = observations()[profileKey],
              previous.subscriptionID == subscriptionID else {
            clearClaims(for: profileKey)
            save(current, for: profileID)
            return []
        }
        if !previous.pendingKeyIDs.isEmpty {
            let visible = Set(visibleKeyIDs)
            let pending = previous.pendingKeyIDs.filter(visible.contains)
            let stillPending = Set(pending)
            claimedKeyIDs[profileKey]?.formIntersection(stillPending)
            removeEmptyClaims(for: profileKey)
            if pending != previous.pendingKeyIDs {
                save(
                    WeeklyResetObservation(
                        subscriptionID: previous.subscriptionID,
                        resetAt: previous.resetAt,
                        pendingKeyIDs: pending
                    ),
                    for: profileID
                )
            }
            return claim(pending, for: profileKey)
        }
        guard resetAt.timeIntervalSince(previous.resetAt) > Self.minimumForwardJump else {
            clearClaims(for: profileKey)
            save(current, for: profileID)
            return []
        }
        let pending = Array(Set(visibleKeyIDs)).sorted()
        clearClaims(for: profileKey)
        save(
            WeeklyResetObservation(
                subscriptionID: subscriptionID,
                resetAt: resetAt,
                pendingKeyIDs: pending
            ),
            for: profileID
        )
        return claim(pending, for: profileKey)
    }

    @discardableResult
    func markKeyHandled(profileID: UUID, keyID: Int, claimToken: UUID? = nil) -> Bool {
        lock.withLock {
            let profileKey = profileID.uuidString
            if let claimToken, claimTokens[profileKey] != claimToken { return false }

            var stored = observations()
            guard var observation = stored[profileKey], observation.pendingKeyIDs.contains(keyID) else {
                return false
            }
            claimedKeyIDs[profileKey]?.remove(keyID)
            removeEmptyClaims(for: profileKey)
            observation.pendingKeyIDs.removeAll { $0 == keyID }
            stored[profileKey] = observation
            persist(stored)
            return true
        }
    }

    func releaseKeyClaims(
        profileID: UUID,
        keyIDs: some Sequence<Int>,
        claimToken: UUID? = nil
    ) {
        lock.withLock {
            let profileKey = profileID.uuidString
            if let claimToken, claimTokens[profileKey] != claimToken { return }
            for keyID in keyIDs {
                claimedKeyIDs[profileKey]?.remove(keyID)
            }
            removeEmptyClaims(for: profileKey)
        }
    }

    func removeObservation(for profileID: UUID) {
        lock.withLock {
            removeObservationLocked(for: profileID)
        }
    }

    private func removeObservationLocked(for profileID: UUID) {
        clearClaims(for: profileID.uuidString)
        var stored = observations()
        guard stored.removeValue(forKey: profileID.uuidString) != nil else { return }
        persist(stored)
    }

    private func claim(_ pending: [Int], for profileKey: String) -> [Int] {
        let claimed = claimedKeyIDs[profileKey, default: []]
        let available = pending.filter { !claimed.contains($0) }
        guard !available.isEmpty else { return [] }
        if claimTokens[profileKey] == nil { claimTokens[profileKey] = UUID() }
        claimedKeyIDs[profileKey, default: []].formUnion(available)
        return available
    }

    private func removeEmptyClaims(for profileKey: String) {
        if claimedKeyIDs[profileKey]?.isEmpty == true {
            clearClaims(for: profileKey)
        }
    }

    private func clearClaims(for profileKey: String) {
        claimedKeyIDs.removeValue(forKey: profileKey)
        claimTokens.removeValue(forKey: profileKey)
    }

    private func save(_ observation: WeeklyResetObservation, for profileID: UUID) {
        var stored = observations()
        stored[profileID.uuidString] = observation
        persist(stored)
    }

    private func observations() -> [String: WeeklyResetObservation] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: WeeklyResetObservation].self, from: data) else {
            return [:]
        }
        return stored
    }

    private func persist(_ observations: [String: WeeklyResetObservation]) {
        guard let data = try? JSONEncoder().encode(observations) else { return }
        defaults.set(data, forKey: key)
    }
}
