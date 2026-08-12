import AppKit

@main
enum OpenAIUsageBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var store: UsageStore!
    private var contentController: UsagePopoverController!
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore()
        contentController = UsagePopoverController(store: store) { [weak self] in
            self?.showPreferences()
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentController

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "OpenAI用量"

        store.onChange = { [weak self] in
            self?.refreshUI()
        }
        refreshUI()

        if store.needsConfiguration {
            DispatchQueue.main.async { [weak self] in
                self?.showPreferences()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if store.needsConfiguration {
            showPreferences()
        } else {
            showPopover()
        }
        return true
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
        statusItem.button?.image = StatusRingRenderer.image(
            progress: store.snapshot.flatMap { $0.hasWeeklyUsage ? $0.progress : nil },
            phase: store.phase
        )
        statusItem.button?.setAccessibilityLabel(accessibilityLabel)
        if popover.isShown {
            contentController.refreshContent()
        }
    }

    private func showPreferences() {
        popover.performClose(nil)
        let controller = PreferencesWindowController(store: store)
        preferencesController = controller
        controller.present()
    }

    private var accessibilityLabel: String {
        guard let snapshot = store.snapshot else {
            return "OpenAI 用量尚不可用"
        }
        let station = store.activeProfile?.name ?? "当前站点"
        guard snapshot.hasWeeklyUsage else {
            return "\(station)周订阅额度不可用，共 \(snapshot.keys.count) 个 API Key"
        }
        let used = String(format: "$%.2f", snapshot.used)
        let total = String(format: "$%.2f", snapshot.total)
        return "\(station)本周用量 \(used)，每周总量 \(total)，已使用 \(Int((snapshot.progress * 100).rounded()))%，共 \(snapshot.keys.count) 个 API Key"
    }
}
