import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let preferencesController: PreferencesViewController

    init(store: UsageStore) {
        preferencesController = PreferencesViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenAI用量设置"
        window.contentViewController = preferencesController
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self

        preferencesController.onSaved = { [weak window] in
            window?.performClose(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class PreferencesViewController: NSViewController, NSTextFieldDelegate {
    var onSaved: (() -> Void)?

    private let store: UsageStore
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let refreshField = NSTextField()
    private let refreshStepper = NSStepper()
    private let launchAtLoginSwitch = NSButton()
    private let showAPIKeyDetailsSwitch = NSButton()
    private let showMetricCardsSwitch = NSButton()
    private let launchStatusLabel = settingsLabel("", size: 11, color: .secondaryLabelColor)
    private let messageLabel = settingsLabel("", size: 11, color: .systemRed)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    init(store: UsageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        configureControls()

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let headerDivider = settingsSeparator()
        let body = makeBody()
        let footerDivider = settingsSeparator()
        let footer = makeFooter()

        [header, headerDivider, body, footerDivider, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 440),
            root.heightAnchor.constraint(equalToConstant: 470),

            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 72),

            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            body.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerDivider.topAnchor.constraint(equalTo: body.bottomAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: footerDivider.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64)
        ])

        view = root
        updateSaveButton()
    }

    private func configureControls() {
        let credentials = store.currentCredentials()
        emailField.stringValue = credentials?.email ?? ""
        passwordField.stringValue = credentials?.password ?? ""
        refreshField.integerValue = Int(store.preferences.refreshInterval)
        launchAtLoginSwitch.state = store.preferences.launchAtLogin ? .on : .off
        showAPIKeyDetailsSwitch.state = store.preferences.showAPIKeyDetails ? .on : .off
        showMetricCardsSwitch.state = store.preferences.showMetricCards ? .on : .off

        configureTextField(emailField, placeholder: "name@example.com")
        configureTextField(passwordField, placeholder: "输入接口密码")
        configureTextField(refreshField, placeholder: "10")
        refreshField.alignment = .right
        refreshField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        refreshField.formatter = settingsRefreshFormatter

        refreshStepper.minValue = UserPreferences.minimumRefreshInterval
        refreshStepper.maxValue = UserPreferences.maximumRefreshInterval
        refreshStepper.increment = 1
        refreshStepper.integerValue = refreshField.integerValue
        refreshStepper.target = self
        refreshStepper.action = #selector(stepRefreshInterval)

        launchAtLoginSwitch.setButtonType(.switch)
        launchAtLoginSwitch.title = "开机自动启动"
        launchAtLoginSwitch.font = NSFont.systemFont(ofSize: 12)
        showAPIKeyDetailsSwitch.setButtonType(.switch)
        showAPIKeyDetailsSwitch.title = "显示 API Key 明细"
        showAPIKeyDetailsSwitch.font = NSFont.systemFont(ofSize: 12)
        showMetricCardsSwitch.setButtonType(.switch)
        showMetricCardsSwitch.title = "显示累计指标卡片"
        showMetricCardsSwitch.font = NSFont.systemFont(ofSize: 12)
        launchStatusLabel.stringValue = store.launchAtLoginStatus

        emailField.delegate = self
        passwordField.delegate = self
        refreshField.delegate = self

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40)
        ])

        let title = settingsLabel("偏好设置", size: 16, weight: .semibold)
        let subtitle = settingsLabel("管理账号、刷新与 Popover 显示", size: 11, color: .secondaryLabelColor)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        return stack
    }

    private func makeBody() -> NSView {
        let accountTitle = settingsLabel("账号", size: 12, weight: .semibold)
        let accountGrid = NSGridView(views: [
            [settingsLabel("接口账号", size: 12), emailField],
            [settingsLabel("密码", size: 12), passwordField]
        ])
        configureGrid(accountGrid)

        let syncTitle = settingsLabel("刷新与启动", size: 12, weight: .semibold)
        let refreshControls = NSStackView(views: [
            refreshField,
            refreshStepper,
            settingsLabel("秒", size: 12),
            settingsLabel("5–3600", size: 10, color: .tertiaryLabelColor)
        ])
        refreshControls.orientation = .horizontal
        refreshControls.alignment = .centerY
        refreshControls.spacing = 7
        refreshField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let launchControls = NSStackView(views: [launchAtLoginSwitch, launchStatusLabel])
        launchControls.orientation = .horizontal
        launchControls.alignment = .centerY
        launchControls.spacing = 10

        let syncGrid = NSGridView(views: [
            [settingsLabel("刷新频率", size: 12), refreshControls],
            [settingsLabel("登录时", size: 12), launchControls]
        ])
        configureGrid(syncGrid)

        let displayTitle = settingsLabel("Popover 显示", size: 12, weight: .semibold)
        let displayOptions = NSStackView(views: [showAPIKeyDetailsSwitch, showMetricCardsSwitch])
        displayOptions.orientation = .vertical
        displayOptions.alignment = .leading
        displayOptions.spacing = 8

        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true

        let stack = NSStackView(views: [
            accountTitle,
            accountGrid,
            settingsSeparator(),
            syncTitle,
            syncGrid,
            settingsSeparator(),
            displayTitle,
            displayOptions,
            messageLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        accountGrid.widthAnchor.constraint(equalToConstant: 392).isActive = true
        syncGrid.widthAnchor.constraint(equalToConstant: 392).isActive = true
        stack.arrangedSubviews[2].widthAnchor.constraint(equalToConstant: 392).isActive = true
        stack.arrangedSubviews[5].widthAnchor.constraint(equalToConstant: 392).isActive = true
        messageLabel.widthAnchor.constraint(equalToConstant: 392).isActive = true
        return stack
    }

    private func makeFooter() -> NSView {
        let lockIcon = NSImageView(image: settingsSymbol("lock.fill", pointSize: 10))
        lockIcon.contentTintColor = .secondaryLabelColor
        let note = settingsLabel("账号密码仅保存在本机钥匙串", size: 11, color: .secondaryLabelColor)
        let spacer = NSView()
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [lockIcon, note, spacer, cancel, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 24, bottom: 14, right: 24)
        return stack
    }

    private func configureGrid(_ grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).width = 76
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        for rowIndex in 0..<grid.numberOfRows {
            grid.row(at: rowIndex).yPlacement = .center
        }
    }

    private func configureTextField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    func controlTextDidChange(_ obj: Notification) {
        updateSaveButton()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === refreshField else { return }
        let normalized = UserPreferences.normalizedRefreshInterval(field.doubleValue)
        refreshField.integerValue = Int(normalized)
        refreshStepper.integerValue = Int(normalized)
    }

    @objc private func save() {
        saveButton.isEnabled = false
        messageLabel.stringValue = ""
        messageLabel.isHidden = true

        Task {
            do {
                try await store.savePreferences(
                    email: emailField.stringValue,
                    password: passwordField.stringValue,
                    refreshInterval: UserPreferences.normalizedRefreshInterval(refreshField.doubleValue),
                    launchAtLogin: launchAtLoginSwitch.state == .on,
                    showAPIKeyDetails: showAPIKeyDetailsSwitch.state == .on,
                    showMetricCards: showMetricCardsSwitch.state == .on
                )
                onSaved?()
            } catch {
                messageLabel.stringValue = store.settingsMessage ?? error.localizedDescription
                messageLabel.isHidden = false
                saveButton.isEnabled = true
            }
        }
    }

    @objc private func cancel() {
        view.window?.performClose(nil)
    }

    @objc private func stepRefreshInterval() {
        refreshField.integerValue = refreshStepper.integerValue
        updateSaveButton()
    }

    private func updateSaveButton() {
        saveButton.isEnabled = !emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !passwordField.stringValue.isEmpty
            && refreshField.doubleValue >= UserPreferences.minimumRefreshInterval
            && refreshField.doubleValue <= UserPreferences.maximumRefreshInterval
    }
}

private let settingsRefreshFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.allowsFloats = false
    formatter.minimum = NSNumber(value: UserPreferences.minimumRefreshInterval)
    formatter.maximum = NSNumber(value: UserPreferences.maximumRefreshInterval)
    return formatter
}()

@MainActor
private func settingsLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

@MainActor
private func settingsSeparator() -> NSBox {
    let separator = NSBox()
    separator.boxType = .separator
    return separator
}

@MainActor
private func settingsSymbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) ?? NSImage()
}
