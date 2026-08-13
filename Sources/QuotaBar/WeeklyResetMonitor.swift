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
        guard enabled else {
            removeObservation(for: profileID)
            return []
        }
        guard let resetAt else { return [] }
        let current = WeeklyResetObservation(subscriptionID: subscriptionID, resetAt: resetAt)
        guard let previous = observations()[profileID.uuidString],
              previous.subscriptionID == subscriptionID else {
            save(current, for: profileID)
            return []
        }
        if !previous.pendingKeyIDs.isEmpty {
            let visible = Set(visibleKeyIDs)
            let pending = previous.pendingKeyIDs.filter(visible.contains)
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
            return pending
        }
        guard resetAt.timeIntervalSince(previous.resetAt) > Self.minimumForwardJump else {
            save(current, for: profileID)
            return []
        }
        let pending = Array(Set(visibleKeyIDs)).sorted()
        save(
            WeeklyResetObservation(
                subscriptionID: subscriptionID,
                resetAt: resetAt,
                pendingKeyIDs: pending
            ),
            for: profileID
        )
        return pending
    }

    func markKeyHandled(profileID: UUID, keyID: Int) {
        var stored = observations()
        guard var observation = stored[profileID.uuidString] else { return }
        observation.pendingKeyIDs.removeAll { $0 == keyID }
        stored[profileID.uuidString] = observation
        persist(stored)
    }

    func removeObservation(for profileID: UUID) {
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
