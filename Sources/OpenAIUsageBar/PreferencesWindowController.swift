import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let preferencesController: PreferencesViewController

    init(store: UsageStore) {
        preferencesController = PreferencesViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
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
    private let tabSelector = NSSegmentedControl()
    private let tabContainer = NSView()
    private var tabViews: [NSView] = []

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

        let header = makeTabHeader()
        let headerDivider = settingsSeparator()
        let body = makeTabBody()
        let footerDivider = settingsSeparator()
        let footer = makeFooter()

        [header, headerDivider, body, footerDivider, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 460),
            root.heightAnchor.constraint(equalToConstant: 390),

            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 74),

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
        launchAtLoginSwitch.title = ""
        launchAtLoginSwitch.font = NSFont.systemFont(ofSize: 12)
        showAPIKeyDetailsSwitch.setButtonType(.switch)
        showAPIKeyDetailsSwitch.title = ""
        showAPIKeyDetailsSwitch.font = NSFont.systemFont(ofSize: 12)
        showMetricCardsSwitch.setButtonType(.switch)
        showMetricCardsSwitch.title = ""
        showMetricCardsSwitch.font = NSFont.systemFont(ofSize: 12)
        launchStatusLabel.stringValue = store.launchAtLoginStatus

        emailField.delegate = self
        passwordField.delegate = self
        refreshField.delegate = self

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        tabSelector.segmentCount = 3
        tabSelector.trackingMode = .selectOne
        tabSelector.segmentStyle = .texturedSquare
        tabSelector.setLabel("账户", forSegment: 0)
        tabSelector.setImage(settingsSymbol("person.crop.circle", pointSize: 17), forSegment: 0)
        tabSelector.setLabel("通用", forSegment: 1)
        tabSelector.setImage(settingsSymbol("gearshape", pointSize: 17), forSegment: 1)
        tabSelector.setLabel("显示", forSegment: 2)
        tabSelector.setImage(settingsSymbol("rectangle.3.group", pointSize: 17), forSegment: 2)
        for segment in 0..<tabSelector.segmentCount {
            tabSelector.setWidth(92, forSegment: segment)
        }
        tabSelector.selectedSegment = 0
        tabSelector.target = self
        tabSelector.action = #selector(changeTab)
    }

    private func makeTabHeader() -> NSView {
        let stack = NSStackView(views: [tabSelector])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        return stack
    }

    private func makeTabBody() -> NSView {
        let account = makeAccountTab()
        let general = makeGeneralTab()
        let display = makeDisplayTab()
        tabViews = [account, general, display]
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        for tab in tabViews {
            tab.translatesAutoresizingMaskIntoConstraints = false
            tabContainer.addSubview(tab)
            NSLayoutConstraint.activate([
                tab.topAnchor.constraint(equalTo: tabContainer.topAnchor),
                tab.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
                tab.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
                tab.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor)
            ])
        }
        updateSelectedTab()
        return tabContainer
    }

    private func makeAccountTab() -> NSView {
        let accountTitle = settingsLabel("账号", size: 12, weight: .semibold)
        let accountGrid = NSGridView(views: [
            [settingsLabel("接口账号", size: 12), emailField],
            [settingsLabel("密码", size: 12), passwordField]
        ])
        configureGrid(accountGrid)
        accountGrid.widthAnchor.constraint(equalToConstant: 384).isActive = true
        return tabStack([accountTitle, settingsPanel(accountGrid), messageLabel])
    }

    private func makeGeneralTab() -> NSView {
        let launchTitle = settingsLabel("启动", size: 12, weight: .semibold)
        let launchRow = settingsRow(title: "登录时自动启动", control: launchAtLoginSwitch)

        let refreshTitle = settingsLabel("刷新", size: 12, weight: .semibold)
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
        let refreshRow = settingsRow(title: "更新间隔", control: refreshControls)

        let status = settingsLabel(store.launchAtLoginStatus, size: 10, color: .secondaryLabelColor)
        return tabStack([
            launchTitle,
            settingsPanel(launchRow),
            status,
            refreshTitle,
            settingsPanel(refreshRow)
        ])
    }

    private func makeDisplayTab() -> NSView {
        let title = settingsLabel("Dashboard 内容", size: 12, weight: .semibold)
        let metrics = settingsRow(title: "累计指标", control: showMetricCardsSwitch)
        let keys = settingsRow(title: "API Key 明细", control: showAPIKeyDetailsSwitch)
        let rows = NSStackView(views: [metrics, settingsSeparator(), keys])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.widthAnchor.constraint(equalToConstant: 384).isActive = true
        rows.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: 380).isActive = true
        return tabStack([title, settingsPanel(rows)])
    }

    private func tabStack(_ views: [NSView]) -> NSView {
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        return stack
    }

    private func settingsPanel(_ content: NSView) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 412),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12)
        ])
        return panel
    }

    private func settingsRow(title: String, control: NSView) -> NSView {
        let titleLabel = settingsLabel(title, size: 12)
        let spacer = NSView()
        let row = NSStackView(views: [titleLabel, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 384).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
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

    @objc private func changeTab() {
        updateSelectedTab()
    }

    private func updateSelectedTab() {
        for (index, tab) in tabViews.enumerated() {
            tab.isHidden = index != tabSelector.selectedSegment
        }
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
