import AppKit
import Foundation

extension Notification.Name {
    static let quotaBarUpdatePreferencesChanged = Notification.Name("QuotaBarUpdatePreferencesChanged")
}

struct DailyUpdateSchedule {
    static func nextNoon(after date: Date, calendar: Calendar = .current) -> Date {
        let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)!
        if date < todayNoon { return todayNoon }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date)!
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrow)!
    }

    static func isDue(now: Date, lastCheck: Date?, calendar: Calendar = .current) -> Bool {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        guard now >= noon else { return false }
        guard let lastCheck else { return true }
        return !calendar.isDate(lastCheck, inSameDayAs: now)
    }
}

struct AutomaticUpdateTaskGeneration {
    private var currentID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    mutating func cancel() {
        currentID = nil
    }

    func isCurrent(_ id: UUID) -> Bool {
        currentID == id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard currentID == id else { return false }
        currentID = nil
        return true
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
    private var checkTaskGeneration = AutomaticUpdateTaskGeneration()
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
            checkTaskGeneration.cancel()
            let task = checkTask
            checkTask = nil
            task?.cancel()
            if task != nil {
                defaults.removeObject(forKey: Self.lastCheckKey)
            }
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
        let generationID = checkTaskGeneration.begin()
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if checkTaskGeneration.finish(generationID) {
                    checkTask = nil
                }
            }
            do {
                let result = try await updater.checkForUpdate(currentVersion: AppVersionInfo.version)
                try Task.checkCancellation()
                guard preferencesStore.load().automaticallyUpdates else { return }
                switch result {
                case .upToDate:
                    defaults.set(now, forKey: Self.lastCheckKey)
                    return
                case .available(let release):
                    try Task.checkCancellation()
                    guard preferencesStore.load().automaticallyUpdates else { return }
                    defaults.set(now, forKey: Self.lastCheckKey)
                    try await updater.installAndRelaunch(release)
                }
            } catch {
                guard checkTaskGeneration.isCurrent(generationID) else { return }
                defaults.removeObject(forKey: Self.lastCheckKey)
                if error is CancellationError || Task.isCancelled { return }
                NSLog("QuotaBar automatic update failed: %@", error.localizedDescription)
            }
        }
    }
}
