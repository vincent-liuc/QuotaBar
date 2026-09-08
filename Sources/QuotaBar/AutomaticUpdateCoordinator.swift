import AppKit
import Foundation

extension Notification.Name {
    static let quotaBarUpdatePreferencesChanged = Notification.Name("QuotaBarUpdatePreferencesChanged")
}

struct DailyUpdateSchedule {
    static func nextNoon(after date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let todayNoon = calendar.date(byAdding: .hour, value: 12, to: startOfDay)!
        if date < todayNoon { return todayNoon }
        return calendar.date(byAdding: .day, value: 1, to: todayNoon)!
    }

    static func isDue(now: Date, lastCheck: Date?, calendar: Calendar = .current) -> Bool {
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))!
        guard now >= noon else { return false }
        guard let lastCheck else { return true }
        return !calendar.isDate(lastCheck, inSameDayAs: now)
    }
}

@MainActor
final class AutomaticUpdateCoordinator {
    private static let lastCheckKey = "lastAutomaticUpdateCheck"

    private let updater: AppUpdater
    private let preferencesStore: PreferencesStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(
        updater: AppUpdater = AppUpdater(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        defaults: UserDefaults = .standard
    ) {
        self.updater = updater
        self.preferencesStore = preferencesStore
        self.defaults = defaults
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .quotaBarUpdatePreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule(checkIfDue: true) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule(checkIfDue: true) }
        })
        reschedule(checkIfDue: true)
    }

    private func reschedule(checkIfDue: Bool) {
        timer?.invalidate()
        timer = nil
        guard preferencesStore.load().automaticallyUpdates else {
            checkTask?.cancel()
            return
        }
        let now = Date()
        let fireDate = DailyUpdateSchedule.nextNoon(after: now)
        timer = Timer(fireAt: fireDate, interval: 0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(timer!, forMode: .common)
        if checkIfDue, DailyUpdateSchedule.isDue(
            now: now,
            lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date
        ) {
            runAutomaticCheck(now: now)
        }
    }

    @objc private func timerFired() {
        runAutomaticCheck(now: Date())
        reschedule(checkIfDue: false)
    }

    private func runAutomaticCheck(now: Date) {
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { checkTask = nil }
            do {
                let result = try await updater.checkForUpdate(currentVersion: AppVersionInfo.version)
                defaults.set(now, forKey: Self.lastCheckKey)
                switch result {
                case .upToDate:
                    return
                case .available(let release):
                    try await updater.installAndRelaunch(release)
                }
            } catch {
                defaults.removeObject(forKey: Self.lastCheckKey)
                NSLog("QuotaBar automatic update failed: %@", error.localizedDescription)
            }
        }
    }
}
