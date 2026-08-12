import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let preferencesController: PreferencesViewController

    init(store: UsageStore) {
        preferencesController = PreferencesViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 310),
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
    private let updater = AppUpdater()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let refreshField = NSTextField()
    private let refreshStepper = NSStepper()
    private let launchAtLoginSwitch = NSSwitch()
    private let showAPIKeyDetailsSwitch = NSSwitch()
    private let showMetricCardsSwitch = NSSwitch()
    private let messageLabel = settingsLabel("", size: 11, color: .systemRed)
    private let updateStatusLabel = settingsLabel("尚未检查", size: 11, color: .secondaryLabelColor)
    private let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let tabContainer = NSView()
    private var tabButtons: [SettingsTabButton] = []
    private var tabViews: [NSView] = []
    private var selectedTab = 0

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
        let body = makeTabBody()
        let footer = makeFooter()
        let headerDivider = settingsSeparator()
        let footerDivider = settingsSeparator()

        [header, headerDivider, body, footerDivider, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 480),
            root.heightAnchor.constraint(equalToConstant: 310),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 64),
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
            footer.heightAnchor.constraint(equalToConstant: 48)
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
        configureTextField(passwordField, placeholder: "输入登录密码")
        refreshField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        refreshField.alignment = .right
        refreshField.isBezeled = false
        refreshField.drawsBackground = false
        refreshField.formatter = settingsRefreshFormatter
        refreshField.widthAnchor.constraint(equalToConstant: 42).isActive = true

        refreshStepper.minValue = UserPreferences.minimumRefreshInterval
        refreshStepper.maxValue = UserPreferences.maximumRefreshInterval
        refreshStepper.increment = 1
        refreshStepper.integerValue = refreshField.integerValue
        refreshStepper.target = self
        refreshStepper.action = #selector(stepRefreshInterval)

        emailField.delegate = self
        passwordField.delegate = self
        refreshField.delegate = self

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .regular
    }

    private func makeTabHeader() -> NSView {
        let tabs: [(String, String)] = [
            ("账户", "person.crop.circle"),
            ("通用", "gearshape"),
            ("显示", "rectangle.3.group"),
            ("更新", "arrow.triangle.2.circlepath")
        ]
        tabButtons = tabs.enumerated().map { index, item in
            let button = SettingsTabButton(title: item.0, symbolName: item.1)
            button.tag = index
            button.target = self
            button.action = #selector(selectTab(_:))
            return button
        }

        let stack = NSStackView(views: tabButtons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        updateSelectedTab()
        return header
    }

    private func makeTabBody() -> NSView {
        tabViews = [makeAccountTab(), makeGeneralTab(), makeDisplayTab(), makeUpdateTab()]
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
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true

        let lockIcon = NSImageView(image: settingsSymbol("lock.fill", pointSize: 9))
        lockIcon.contentTintColor = .secondaryLabelColor
        let keychainNote = settingsLabel("账号密码仅保存在本机钥匙串", size: 10,
                                         color: .secondaryLabelColor)
        let note = NSStackView(views: [lockIcon, keychainNote])
        note.orientation = .horizontal
        note.alignment = .centerY
        note.spacing = 5

        return tabStack([
            sectionTitle("账户"),
            settingsPanel([
                fieldRow(title: "登录账号", field: emailField),
                fieldRow(title: "登录密码", field: passwordField)
            ]),
            messageLabel
        ], bottomView: note)
    }

    private func makeGeneralTab() -> NSView {
        let refreshControls = NSStackView(views: [
            refreshField,
            settingsLabel("秒", size: 13),
            refreshStepper
        ])
        refreshControls.orientation = .horizontal
        refreshControls.alignment = .centerY
        refreshControls.spacing = 7
        return tabStack([
            sectionTitle("启动"),
            settingsPanel([
                settingsRow(title: "登录时自动启动", control: launchAtLoginSwitch)
            ]),
            sectionTitle("监控"),
            settingsPanel([
                settingsRow(title: "更新间隔", control: refreshControls)
            ])
        ])
    }

    private func makeDisplayTab() -> NSView {
        return tabStack([
            sectionTitle("Dashboard组件设置"),
            settingsPanel([
                settingsRow(title: "累计指标", control: showMetricCardsSwitch),
                settingsRow(title: "API Key 明细", control: showAPIKeyDetailsSwitch)
            ])
        ])
    }

    private func makeUpdateTab() -> NSView {
        let version = settingsLabel("\(AppVersionInfo.version) (\(AppVersionInfo.build))", size: 12,
                                    color: .secondaryLabelColor)
        return tabStack([
            sectionTitle("软件更新"),
            settingsPanel([
                settingsRow(title: "当前版本", control: version),
                settingsRow(title: "版本更新", control: updateButton)
            ]),
            updateStatusLabel
        ])
    }

    private func tabStack(_ views: [NSView], bottomView: NSView? = nil) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        var arrangedViews = views + [spacer]
        if let bottomView { arrangedViews.append(bottomView) }
        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 14, right: 24)
        for view in views {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        return stack
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        settingsLabel(title, size: 13, weight: .semibold)
    }

    private func settingsPanel(_ rows: [NSView]) -> NSView {
        var arranged: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { arranged.append(settingsSeparator()) }
            arranged.append(row)
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 9
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 432),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        for view in stack.arrangedSubviews where view is NSBox {
            view.widthAnchor.constraint(equalToConstant: 404).isActive = true
        }
        return panel
    }

    private func settingsRow(title: String, control: NSView) -> NSView {
        let titleLabel = settingsLabel(title, size: 13, weight: .medium)
        let spacer = NSView()
        let row = NSStackView(views: [titleLabel, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 404).isActive = true
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return row
    }

    private func fieldRow(title: String, field: NSTextField) -> NSView {
        field.widthAnchor.constraint(equalToConstant: 276).isActive = true
        return settingsRow(title: title, control: field)
    }

    private func makeFooter() -> NSView {
        let spacer = NSView()
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        let stack = NSStackView(views: [spacer, cancel, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        return stack
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
                selectTab(at: 0)
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

    @objc private func selectTab(_ sender: SettingsTabButton) {
        selectTab(at: sender.tag)
    }

    private func selectTab(at index: Int) {
        selectedTab = index
        updateSelectedTab()
    }

    private func updateSelectedTab() {
        for (index, button) in tabButtons.enumerated() {
            button.isSelectedTab = index == selectedTab
        }
        for (index, tab) in tabViews.enumerated() {
            tab.isHidden = index != selectedTab
        }
    }

    @objc private func checkForUpdates() {
        updateButton.isEnabled = false
        updateButton.title = "检查中…"
        updateStatusLabel.stringValue = "正在检查"
        Task {
            do {
                let result = try await updater.checkForUpdate(currentVersion: AppVersionInfo.version)
                switch result {
                case .upToDate(let latestVersion):
                    updateStatusLabel.stringValue = "已是最新版本 \(latestVersion)"
                case .available(let release):
                    updateButton.title = "下载中…"
                    updateStatusLabel.stringValue = "正在下载 \(release.version)"
                    let fileURL = try await updater.download(release)
                    updateStatusLabel.stringValue = "已下载 \(release.version)"
                    NSWorkspace.shared.open(fileURL)
                }
            } catch {
                updateStatusLabel.stringValue = error.localizedDescription
            }
            updateButton.title = "检查更新"
            updateButton.isEnabled = true
        }
    }

    private func updateSaveButton() {
        saveButton.isEnabled = !emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !passwordField.stringValue.isEmpty
            && refreshField.doubleValue >= UserPreferences.minimumRefreshInterval
            && refreshField.doubleValue <= UserPreferences.maximumRefreshInterval
    }
}

@MainActor
private final class SettingsTabButton: NSButton {
    var isSelectedTab = false {
        didSet { updateAppearance() }
    }

    private let iconView: NSImageView
    private let titleLabel: NSTextField

    init(title: String, symbolName: String) {
        iconView = NSImageView(image: settingsSymbol(symbolName, pointSize: 18))
        titleLabel = settingsLabel(title, size: 11)
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20)
        ])
        let content = NSStackView(views: [iconView, titleLabel])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 60),
            heightAnchor.constraint(equalToConstant: 48),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelectedTab else { return }
        let radius: CGFloat = 8
        let fill = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        fill.fill()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: radius,
            yRadius: radius
        )
        border.lineWidth = lineWidth
        NSColor.separatorColor.withAlphaComponent(0.42).setStroke()
        border.stroke()
    }

    private func updateAppearance() {
        let color: NSColor = isSelectedTab ? .controlAccentColor : .secondaryLabelColor
        iconView.contentTintColor = color
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: isSelectedTab ? .semibold : .regular)
        titleLabel.textColor = color
        needsDisplay = true
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
    separator.alphaValue = 0.45
    return separator
}

@MainActor
private func settingsSymbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) ?? NSImage()
}
