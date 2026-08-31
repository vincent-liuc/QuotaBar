import AppKit

@MainActor
final class ComputerUseBridgeController: NSObject {
    private let panel: ComputerUseBridgePanel
    private let action: () -> Void
    private weak var anchorView: NSView?

    init(anchorView: NSView, action: @escaping () -> Void) {
        self.anchorView = anchorView
        self.action = action
        panel = ComputerUseBridgePanel(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let button = ComputerUseBridgeButton()
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = #selector(showDashboard)
        button.onAccessibilityPress = { [weak self] in
            self?.action()
        }
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "显示 Dashboard") { [weak self] in
                self?.action()
                return true
            }
        ])
        button.setAccessibilityIdentifier("QuotaBar.ComputerUseBridge.ShowDashboard")
        button.setAccessibilityLabel("显示 Dashboard")
        button.setAccessibilityHelp("打开 QuotaBar Dashboard")

        panel.contentView = button
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.04
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show() {
        guard positionPanel() else { return }
        panel.orderFrontRegardless()
    }

    @objc private func showDashboard() {
        action()
    }

    @objc private func screenParametersDidChange() {
        _ = positionPanel()
    }

    @discardableResult
    private func positionPanel() -> Bool {
        guard let anchorView, let anchorWindow = anchorView.window else { return false }
        let anchorRect = anchorWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: anchorRect.midX - size.width / 2,
            y: anchorRect.midY - size.height / 2
        ))
        return true
    }
}

private final class ComputerUseBridgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ComputerUseBridgeButton: NSButton {
    var onAccessibilityPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onAccessibilityPress?()
        return true
    }
}
