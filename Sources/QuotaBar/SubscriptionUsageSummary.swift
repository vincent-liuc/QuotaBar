import Foundation

struct SubscriptionUsageSummary: Equatable, Sendable {
    let weeklyUsage: WeeklyUsage?
    let dailyUsage: DailyUsage?

    init(subscriptions: [SubscriptionRecord], now: Date = Date()) {
        var seenIDs: Set<Int> = []
        let selected = subscriptions.filter { subscription in
            guard subscription.status == "active",
                  subscription.expiresAt.map({ $0 > now }) ?? true else { return false }
            if let id = subscription.id, !seenIDs.insert(id).inserted { return false }
            return true
        }
        let weekly = selected.compactMap { subscription -> WeeklyUsage? in
            guard let total = subscription.weeklyLimitUSD else { return nil }
            return WeeklyUsage(
                subscriptionID: subscription.id,
                used: max(subscription.weeklyUsageUSD ?? 0, 0),
                total: max(total, 0),
                resetAt: WeeklyResetCalculator.nextReset(
                    windowStart: subscription.weeklyWindowStart,
                    expiresAt: subscription.expiresAt,
                    now: now
                ),
                windowStart: subscription.weeklyWindowStart
            )
        }
        if weekly.count > 1 {
            weeklyUsage = WeeklyUsage(
                used: weekly.reduce(0) { $0 + $1.used },
                total: weekly.reduce(0) { $0 + $1.total },
                // This is the next individual reset, not a shared reset for all subscriptions.
                resetAt: weekly.compactMap(\.resetAt).min(),
                subscriptionCount: weekly.count,
                remaining: weekly.reduce(0) { $0 + $1.remaining }
            )
        } else {
            weeklyUsage = weekly.first
        }

        let daily = selected.compactMap { subscription -> DailyUsage? in
            guard let total = subscription.dailyLimitUSD else { return nil }
            return DailyUsage(
                subscriptionID: subscription.id,
                subscriptionName: subscription.name,
                used: max(subscription.dailyUsageUSD ?? 0, 0),
                total: max(total, 0),
                resetAt: DailyResetCalculator.nextReset(
                    windowStart: subscription.dailyWindowStart,
                    expiresAt: subscription.expiresAt,
                    now: now
                )
            )
        }
        if daily.count > 1 {
            dailyUsage = DailyUsage(
                used: daily.reduce(0) { $0 + $1.used },
                total: daily.reduce(0) { $0 + $1.total },
                resetAt: daily.compactMap(\.resetAt).min(),
                subscriptionCount: daily.count
            )
        } else {
            dailyUsage = daily.first
        }
    }
}
