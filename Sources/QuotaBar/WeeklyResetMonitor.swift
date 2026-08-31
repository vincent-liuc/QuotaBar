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

final class WeeklyResetMonitor: @unchecked Sendable {
    static let minimumForwardJump: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let key = "weeklyResetObservations.v1"
    private let lock = NSLock()
    private var claimedKeyIDs: [String: Set<Int>] = [:]

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
        lock.withLock {
            let profileKey = profileID.uuidString
            guard enabled else {
                removeObservationUnlocked(for: profileID)
                return []
            }
            guard let resetAt else { return [] }
            let current = WeeklyResetObservation(subscriptionID: subscriptionID, resetAt: resetAt)
            guard let previous = observations()[profileKey],
                  previous.subscriptionID == subscriptionID else {
                claimedKeyIDs[profileKey] = nil
                save(current, for: profileID)
                return []
            }

            let pending: [Int]
            if !previous.pendingKeyIDs.isEmpty {
                let visible = Set(visibleKeyIDs)
                pending = previous.pendingKeyIDs.filter(visible.contains)
                claimedKeyIDs[profileKey]?.formIntersection(visible)
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
            } else {
                guard resetAt.timeIntervalSince(previous.resetAt) > Self.minimumForwardJump else {
                    claimedKeyIDs[profileKey] = nil
                    save(current, for: profileID)
                    return []
                }
                pending = Array(Set(visibleKeyIDs)).sorted()
                save(
                    WeeklyResetObservation(
                        subscriptionID: subscriptionID,
                        resetAt: resetAt,
                        pendingKeyIDs: pending
                    ),
                    for: profileID
                )
            }

            let claimed = claimedKeyIDs[profileKey] ?? []
            let plan = pending.filter { !claimed.contains($0) }
            claimedKeyIDs[profileKey, default: []].formUnion(plan)
            return plan
        }
    }

    func markKeyHandled(profileID: UUID, keyID: Int) {
        lock.withLock {
            let profileKey = profileID.uuidString
            claimedKeyIDs[profileKey]?.remove(keyID)
            var stored = observations()
            guard var observation = stored[profileKey] else { return }
            observation.pendingKeyIDs.removeAll { $0 == keyID }
            stored[profileKey] = observation
            persist(stored)
        }
    }

    func markKeyFailed(profileID: UUID, keyID: Int) {
        lock.withLock {
            claimedKeyIDs[profileID.uuidString]?.remove(keyID)
        }
    }

    func removeObservation(for profileID: UUID) {
        lock.withLock {
            removeObservationUnlocked(for: profileID)
        }
    }

    private func removeObservationUnlocked(for profileID: UUID) {
        claimedKeyIDs[profileID.uuidString] = nil
        var stored = observations()
        guard stored.removeValue(forKey: profileID.uuidString) != nil else { return }
        persist(stored)
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
