import AppKit

@main
enum QuotaBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           let existingApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                .quotaBarShowDashboard,
                object: bundleIdentifier,
                deliverImmediately: true
            )
            existingApplication.activate(options: [.activateAllWindows])
            return
        }
        let delegate = AppController()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.mainMenu = makeMainMenu(target: delegate)
        application.run()
        _ = delegate
    }

    @MainActor
    private static func makeMainMenu(target: AppController) -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "QuotaBar")
        let showDashboardItem = NSMenuItem(
            title: "显示 Dashboard",
            action: #selector(AppController.showDashboard(_:)),
            keyEquivalent: "d"
        )
        showDashboardItem.keyEquivalentModifierMask = [.command, .shift]
        showDashboardItem.target = target
        applicationMenu.addItem(showDashboardItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "退出 QuotaBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        let closeItem = NSMenuItem(
            title: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        windowMenu.addItem(closeItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu
        return mainMenu
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var store: UsageStore!
    private var contentController: UsagePopoverController!
    private var preferencesController: PreferencesWindowController?
    private var statusAnimationTimer: Timer?
    private var automaticUpdateCoordinator: AutomaticUpdateCoordinator?
    private var computerUseBridge: ComputerUseBridgeController?
    private var wavePhase = 0.0
    private var tailPhase = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDataMigration.migrateLegacyDefaultsIfNeeded()
        store = UsageStore()
        contentController = UsagePopoverController(store: store) { [weak self] tab in
            self?.showPreferences(tab: tab)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentController

        statusItem.autosaveName = "QuotaBar.StatusItem"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "QuotaBar"
        button.setAccessibilityIdentifier("QuotaBar.StatusItem")
        button.setAccessibilityHelp("打开 Dashboard")

        store.onChange = { [weak self] in
            self?.refreshUI()
        }
        refreshUI()
        automaticUpdateCoordinator = AutomaticUpdateCoordinator()
        automaticUpdateCoordinator?.start()
        statusAnimationTimer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let progress = self.store.snapshot?.progress, progress > 0, progress < 1 {
                    self.wavePhase += .pi / 5
                }
                self.tailPhase += .pi / 8
                self.refreshStatusIcon()
            }
        }
        RunLoop.main.add(statusAnimationTimer!, forMode: .common)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowDashboardNotification(_:)),
            name: .quotaBarShowDashboard,
            object: Bundle.main.bundleIdentifier
        )
        computerUseBridge = ComputerUseBridgeController(anchorView: button) { [weak self] in self?.togglePopover() }
        computerUseBridge?.show()
        DispatchQueue.main.async { [weak self] in self?.computerUseBridge?.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    @objc func showDashboard(_ sender: Any?) {
        showPopover()
    }

    @objc private func handleShowDashboardNotification(_ notification: Notification) {
        showPopover()
    }

    @objc private func togglePopover() {
        guard statusItem.button != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        contentController.refreshContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func refreshUI() {
        refreshStatusIcon()
        statusItem.button?.setAccessibilityLabel(accessibilityLabel)
        if popover.isShown {
            contentController.refreshContent()
        }
    }

    private func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = StatusRingRenderer.image(
            progress: store.snapshot.flatMap { $0.hasWeeklyUsage ? $0.progress : nil },
            phase: store.phase,
            wavePhase: wavePhase,
            tailPhase: tailPhase
        )
        button.needsDisplay = true
    }

    private func showPreferences(tab: SettingsTab = .general) {
        popover.performClose(nil)
        let controller = PreferencesWindowController(store: store)
        preferencesController = controller
        controller.present(tab: tab)
    }

    private var accessibilityLabel: String {
        guard let snapshot = store.snapshot else {
            return "QuotaBar 用量尚不可用"
        }
        let station = store.activeProfile?.name ?? "当前站点"
        guard snapshot.hasWeeklyUsage else {
            return "\(station)额度不可用，共 \(snapshot.keys.count) 个 API Key"
        }
        let used = String(format: "$%.2f", snapshot.used)
        let total = String(format: "$%.2f", snapshot.total)
        let usageTitle: String
        let totalTitle: String
        switch snapshot.weeklyUsage?.kind {
        case .accountPool:
            usageTitle = "历史消耗"
            totalTitle = "账户总量"
        case .tokenPool:
            usageTitle = "令牌已用"
            totalTitle = "令牌总额"
        case .weekly, .none:
            usageTitle = "本周用量"
            totalTitle = "每周总量"
        }
        return "\(station)\(usageTitle) \(used)，\(totalTitle) \(total)，已使用 \(Int((snapshot.progress * 100).rounded()))%，共 \(snapshot.keys.count) 个 API Key"
    }
}

private extension Notification.Name {
    static let quotaBarShowDashboard = Notification.Name("dev.ruobin.QuotaBar.showDashboard")
}
