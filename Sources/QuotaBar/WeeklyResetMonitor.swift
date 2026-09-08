import Foundation

struct WeeklyResetObservation: Codable, Equatable, Sendable {
    let subscriptionID: Int?
    let windowStart: Date
    var pendingKeyIDs: [Int]

    init(subscriptionID: Int?, windowStart: Date, pendingKeyIDs: [Int] = []) {
        self.subscriptionID = subscriptionID
        self.windowStart = windowStart
        self.pendingKeyIDs = pendingKeyIDs
    }
}

final class WeeklyResetMonitor: @unchecked Sendable {
    private let defaults: UserDefaults
    // Countdown-based v1 observations cannot identify actual server cycles reliably.
    private let key = "weeklyResetObservations.v2"
    private let lock = NSLock()
    private var claimedKeyIDs: [String: Set<Int>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resetPlan(
        profileID: UUID,
        subscriptionID: Int?,
        windowStart: Date?,
        enabled: Bool,
        visibleKeyIDs: [Int],
        subscriptionCount: Int = 1
    ) -> [Int] {
        lock.withLock {
            let profileKey = profileID.uuidString
            // A reset of one subscription must not clear keys belonging to the others.
            guard enabled, subscriptionCount == 1 else {
                removeObservationUnlocked(for: profileID)
                return []
            }
            guard let windowStart else { return [] }
            let current = WeeklyResetObservation(subscriptionID: subscriptionID, windowStart: windowStart)
            guard let previous = observations()[profileKey],
                  previous.subscriptionID == subscriptionID else {
                claimedKeyIDs[profileKey] = nil
                save(current, for: profileID)
                return []
            }

            let pending: [Int]
            if windowStart <= previous.windowStart {
                let visible = Set(visibleKeyIDs)
                pending = previous.pendingKeyIDs.filter(visible.contains)
                claimedKeyIDs[profileKey]?.formIntersection(visible)
                if pending != previous.pendingKeyIDs {
                    save(
                        WeeklyResetObservation(
                            subscriptionID: previous.subscriptionID,
                            windowStart: previous.windowStart,
                            pendingKeyIDs: pending
                        ),
                        for: profileID
                    )
                }
            } else {
                claimedKeyIDs[profileKey] = nil
                pending = Array(Set(visibleKeyIDs)).sorted()
                save(
                    WeeklyResetObservation(
                        subscriptionID: subscriptionID,
                        windowStart: windowStart,
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
        _ = lock.withLock {
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
