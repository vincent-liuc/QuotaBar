import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let preferencesController: PreferencesViewController

    init(store: UsageStore) {
        preferencesController = PreferencesViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentViewController = preferencesController
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        preferencesController.reloadFromStore()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }
}

@MainActor
private final class PreferencesViewController: NSViewController, NSTextFieldDelegate {
    private let store: UsageStore
    private let updater = AppUpdater()
    private var editingProfile: StationProfile
    private var profiles: [StationProfile]
    private var subscriptions: [SubscriptionOption] = []

    private let profilePopup = NSPopUpButton()
    private let addProfileButton = NSButton()
    private let deleteProfileButton = NSButton()
    private let nameField = NSTextField()
    private let serviceURLField = NSTextField()
    private let apiPathField = NSTextField()
    private let timezonePopup = NSPopUpButton()
    private let subscriptionPopup = NSPopUpButton()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let visiblePasswordField = NSTextField()
    private let passwordContainer = NSView()
    private let passwordVisibilityButton = NSButton()
    private let loginTestButton = NSButton(title: "测试登录", target: nil, action: nil)
    private let loginStatusLabel = settingsLabel("尚未测试", size: 11, color: .secondaryLabelColor)
    private let refreshField = NSTextField()
    private let refreshStepper = NSStepper()
    private let launchAtLoginSwitch = NSSwitch()
    private let showAPIKeyDetailsSwitch = NSSwitch()
    private let showMetricCardsSwitch = NSSwitch()
    private let showUsageHistorySwitch = NSSwitch()
    private let messageLabel = settingsLabel("", size: 11, color: .systemRed)
    private let connectionLabel = settingsLabel("尚未检测", size: 11, color: .secondaryLabelColor)
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let updateStatusLabel = settingsLabel("尚未检查", size: 11, color: .secondaryLabelColor)
    private let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let tabContainer = NSView()
    private var tabButtons: [SettingsTabButton] = []
    private var tabViews: [NSView] = []
    private var selectedTab = 0
    private var isLoadingControls = false
    private var statusBarHeightConstraint: NSLayoutConstraint?

    init(store: UsageStore) {
        self.store = store
        profiles = store.profiles
        editingProfile = store.activeProfile ?? StationProfile.legacyDefault()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reloadFromStore() {
        guard isViewLoaded else { return }
        profiles = store.profiles
        loadProfile(store.activeProfile ?? editingProfile)
    }

    override func loadView() {
        configureControls()
        let root = NSView()
        let profileBar = makeProfileBar()
        let header = makeTabHeader()
        let body = makeTabBody()
        let statusBar = makeStatusBar()
        let headerDivider = settingsSeparator()
        [profileBar, header, headerDivider, body, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        let statusBarHeight = statusBar.heightAnchor.constraint(equalToConstant: 0)
        statusBarHeightConstraint = statusBarHeight
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 540),
            root.heightAnchor.constraint(equalToConstant: 450),
            profileBar.topAnchor.constraint(equalTo: root.topAnchor),
            profileBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            profileBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            profileBar.heightAnchor.constraint(equalToConstant: 48),
            header.topAnchor.constraint(equalTo: profileBar.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 58),
            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: body.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBarHeight
        ])
        view = root
        loadProfile(editingProfile)
    }

    private func configureControls() {
        [nameField, serviceURLField, apiPathField, emailField, passwordField, visiblePasswordField, refreshField].forEach {
            $0.delegate = self
        }
        configureTextField(nameField, placeholder: "例如：主站")
        configureTextField(serviceURLField, placeholder: "https://example.com")
        configureTextField(apiPathField, placeholder: "/api/v1")
        configureTextField(emailField, placeholder: "name@example.com")
        configureTextField(passwordField, placeholder: "输入登录密码")
        configureTextField(visiblePasswordField, placeholder: "输入登录密码")
        configurePasswordControl()

        refreshField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        refreshField.alignment = .right
        refreshField.formatter = settingsRefreshFormatter
        refreshField.widthAnchor.constraint(equalToConstant: 42).isActive = true
        refreshField.integerValue = Int(store.preferences.refreshInterval)
        refreshStepper.minValue = UserPreferences.minimumRefreshInterval
        refreshStepper.maxValue = UserPreferences.maximumRefreshInterval
        refreshStepper.increment = 1
        refreshStepper.integerValue = refreshField.integerValue
        refreshStepper.target = self
        refreshStepper.action = #selector(stepRefreshInterval)
        launchAtLoginSwitch.state = store.preferences.launchAtLogin ? .on : .off
        showAPIKeyDetailsSwitch.state = store.preferences.showAPIKeyDetails ? .on : .off
        showMetricCardsSwitch.state = store.preferences.showMetricCards ? .on : .off
        showUsageHistorySwitch.state = store.preferences.showUsageHistory ? .on : .off

        let timezoneIDs = ["Asia/Shanghai", TimeZone.current.identifier, "UTC"].uniqued()
        timezonePopup.addItems(withTitles: timezoneIDs)
        subscriptionPopup.addItem(withTitle: "自动选择")
        timezonePopup.target = self
        timezonePopup.action = #selector(profileSelectionChanged)
        subscriptionPopup.target = self
        subscriptionPopup.action = #selector(profileSelectionChanged)
        [launchAtLoginSwitch, showAPIKeyDetailsSwitch, showMetricCardsSwitch, showUsageHistorySwitch].forEach {
            $0.target = self
            $0.action = #selector(preferenceControlChanged)
        }

        configureIconButton(addProfileButton, symbol: "plus", toolTip: "添加站点")
        configureIconButton(deleteProfileButton, symbol: "minus", toolTip: "删除站点")
        addProfileButton.target = self
        addProfileButton.action = #selector(addProfile)
        deleteProfileButton.target = self
        deleteProfileButton.action = #selector(deleteProfile)
        profilePopup.target = self
        profilePopup.action = #selector(changeProfile)
        testButton.target = self
        testButton.action = #selector(testConnection)
        loginTestButton.target = self
        loginTestButton.action = #selector(testLogin)
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        [testButton, loginTestButton, updateButton].forEach { $0.bezelStyle = .rounded }
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true
    }

    private func makeProfileBar() -> NSView {
        let title = settingsLabel("当前站点", size: 12, weight: .medium)
        profilePopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        reloadProfilePopup()
        let spacer = NSView()
        let stack = NSStackView(views: [title, profilePopup, addProfileButton, deleteProfileButton, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 4, right: 20)
        return stack
    }

    private func makeTabHeader() -> NSView {
        let tabs = [
            ("站点", "server.rack"), ("账户", "person.crop.circle"),
            ("通用", "gearshape"), ("显示", "rectangle.3.group"),
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
        stack.spacing = 4
        let header = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        updateSelectedTab()
        return header
    }

    private func makeTabBody() -> NSView {
        tabViews = [makeStationTab(), makeAccountTab(), makeGeneralTab(), makeDisplayTab(), makeUpdateTab()]
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

    private func makeStationTab() -> NSView {
        return tabStack([
            sectionTitle("Sub2API 站点"),
            settingsPanel([
                fieldRow(title: "站点名称", field: nameField),
                fieldRow(title: "服务地址", field: serviceURLField),
                fieldRow(title: "API 路径", field: apiPathField),
                settingsRow(title: "时区", control: timezonePopup),
                settingsRow(title: "订阅", control: subscriptionPopup)
            ]),
            settingsRow(title: "兼容性检测", control: testButton),
            connectionLabel
        ])
    }

    private func makeAccountTab() -> NSView {
        let lockIcon = NSImageView(image: settingsSymbol("lock.fill", pointSize: 9))
        lockIcon.contentTintColor = .secondaryLabelColor
        let note = NSStackView(views: [lockIcon, settingsLabel("账号密码仅保存在本机应用支持目录", size: 10, color: .secondaryLabelColor)])
        note.orientation = .horizontal
        note.alignment = .centerY
        note.spacing = 5
        let loginControls = NSStackView(views: [loginTestButton, loginStatusLabel])
        loginControls.orientation = .horizontal
        loginControls.alignment = .centerY
        loginControls.spacing = 9
        return tabStack([
            sectionTitle("账户"),
            settingsPanel([
                fieldRow(title: "登录账号", field: emailField),
                settingsRow(title: "登录密码", control: passwordContainer),
                settingsRow(title: "登录验证", control: loginControls)
            ])
        ], bottomView: note)
    }

    private func makeGeneralTab() -> NSView {
        let refreshControls = NSStackView(views: [refreshField, settingsLabel("秒", size: 13), refreshStepper])
        refreshControls.orientation = .horizontal
        refreshControls.alignment = .centerY
        refreshControls.spacing = 7
        return tabStack([
            sectionTitle("启动"), settingsPanel([settingsRow(title: "登录时自动启动", control: launchAtLoginSwitch)]),
            sectionTitle("监控"), settingsPanel([settingsRow(title: "更新间隔", control: refreshControls)])
        ])
    }

    private func makeDisplayTab() -> NSView {
        tabStack([
            sectionTitle("Dashboard组件设置"),
            settingsPanel([
                settingsRow(title: "累计指标", control: showMetricCardsSwitch),
                settingsRow(title: "API Key 明细", control: showAPIKeyDetailsSwitch),
                settingsRow(title: "使用记录", control: showUsageHistorySwitch)
            ])
        ])
    }

    private func makeUpdateTab() -> NSView {
        let version = settingsLabel("\(AppVersionInfo.version) (\(AppVersionInfo.build))", size: 12, color: .secondaryLabelColor)
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
        var arranged = views + [spacer]
        if let bottomView { arranged.append(bottomView) }
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
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
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 492),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        return panel
    }

    private func settingsRow(title: String, control: NSView) -> NSView {
        let titleLabel = settingsLabel(title, size: 13, weight: .medium)
        let row = NSStackView(views: [titleLabel, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return row
    }

    private func fieldRow(title: String, field: NSTextField) -> NSView {
        field.widthAnchor.constraint(equalToConstant: 330).isActive = true
        return settingsRow(title: title, control: field)
    }

    private func makeStatusBar() -> NSView {
        let stack = NSStackView(views: [messageLabel, NSView()])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 20, bottom: 5, right: 20)
        return stack
    }

    private func configureTextField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func configurePasswordControl() {
        visiblePasswordField.isHidden = true
        configureIconButton(passwordVisibilityButton, symbol: "eye", toolTip: "显示密码")
        passwordVisibilityButton.target = self
        passwordVisibilityButton.action = #selector(togglePasswordVisibility)
        passwordVisibilityButton.bezelStyle = .inline
        passwordContainer.widthAnchor.constraint(equalToConstant: 330).isActive = true
        passwordContainer.heightAnchor.constraint(equalToConstant: 26).isActive = true
        [passwordField, visiblePasswordField, passwordVisibilityButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            passwordContainer.addSubview($0)
        }
        NSLayoutConstraint.activate([
            passwordField.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: passwordVisibilityButton.leadingAnchor, constant: -4),
            passwordField.centerYAnchor.constraint(equalTo: passwordContainer.centerYAnchor),
            visiblePasswordField.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            visiblePasswordField.trailingAnchor.constraint(equalTo: passwordVisibilityButton.leadingAnchor, constant: -4),
            visiblePasswordField.centerYAnchor.constraint(equalTo: passwordContainer.centerYAnchor),
            passwordVisibilityButton.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor),
            passwordVisibilityButton.centerYAnchor.constraint(equalTo: passwordContainer.centerYAnchor)
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, toolTip: String) {
        button.image = settingsSymbol(symbol, pointSize: 12)
        button.title = ""
        button.toolTip = toolTip
        button.bezelStyle = .texturedRounded
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField { synchronizePasswordFields(from: field) }
        clearMessage()
        loginStatusLabel.stringValue = "尚未测试"
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isLoadingControls, let field = obj.object as? NSTextField else { return }
        synchronizePasswordFields(from: field)
        if field === refreshField {
            refreshField.integerValue = Int(UserPreferences.normalizedRefreshInterval(field.doubleValue))
            refreshStepper.integerValue = refreshField.integerValue
            persistPreferences()
        } else {
            persistProfileFromControls()
        }
    }

    private func profileFromControls() -> StationProfile {
        var profile = editingProfile
        profile.name = nameField.stringValue
        profile.serviceURL = serviceURLField.stringValue
        profile.apiPath = apiPathField.stringValue
        profile.timezone = timezonePopup.titleOfSelectedItem ?? TimeZone.current.identifier
        if subscriptionPopup.indexOfSelectedItem <= 0 {
            profile.subscriptionSelection = .automatic
        } else if let id = subscriptionPopup.selectedItem?.representedObject as? Int {
            profile.subscriptionSelection = .manual(id)
        }
        return profile
    }

    private var enteredCredentials: Credentials {
        Credentials(email: emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), password: passwordField.stringValue)
    }

    private func synchronizePasswordFields(from field: NSTextField) {
        if field === passwordField {
            visiblePasswordField.stringValue = passwordField.stringValue
        } else if field === visiblePasswordField {
            passwordField.stringValue = visiblePasswordField.stringValue
        }
    }

    private func loadProfile(_ profile: StationProfile) {
        isLoadingControls = true
        defer { isLoadingControls = false }
        editingProfile = profile
        nameField.stringValue = profile.name
        serviceURLField.stringValue = profile.serviceURL
        apiPathField.stringValue = profile.apiPath
        if timezonePopup.indexOfItem(withTitle: profile.timezone) < 0 { timezonePopup.addItem(withTitle: profile.timezone) }
        timezonePopup.selectItem(withTitle: profile.timezone)
        let credentials = store.credentials(for: profile.id)
        emailField.stringValue = credentials?.email ?? ""
        passwordField.stringValue = credentials?.password ?? ""
        visiblePasswordField.stringValue = passwordField.stringValue
        loginStatusLabel.stringValue = "尚未测试"
        subscriptions = []
        reloadSubscriptionPopup(selection: profile.subscriptionSelection)
        connectionLabel.stringValue = capabilitySummary(profile)
        deleteProfileButton.isEnabled = profiles.count > 1
        reloadProfilePopup()
    }

    private func reloadProfilePopup() {
        profilePopup.removeAllItems()
        for profile in profiles {
            profilePopup.addItem(withTitle: profile.name)
            profilePopup.lastItem?.representedObject = profile.id
        }
        if let index = profiles.firstIndex(where: { $0.id == editingProfile.id }) { profilePopup.selectItem(at: index) }
    }

    private func reloadSubscriptionPopup(selection: SubscriptionSelection) {
        subscriptionPopup.removeAllItems()
        subscriptionPopup.addItem(withTitle: "自动选择")
        for option in subscriptions {
            subscriptionPopup.addItem(withTitle: "\(option.name)\(option.status == "active" ? "" : "（已停用）")")
            subscriptionPopup.lastItem?.representedObject = option.id
            subscriptionPopup.lastItem?.isEnabled = option.status == "active"
        }
        if case .manual(let id) = selection {
            if let index = subscriptionPopup.itemArray.firstIndex(where: { ($0.representedObject as? Int) == id }) {
                subscriptionPopup.selectItem(at: index)
            } else {
                subscriptionPopup.addItem(withTitle: "订阅 #\(id)（已保存）")
                subscriptionPopup.lastItem?.representedObject = id
                subscriptionPopup.select(subscriptionPopup.lastItem)
            }
        } else {
            subscriptionPopup.selectItem(at: 0)
        }
    }

    private func capabilitySummary(_ profile: StationProfile) -> String {
        guard let checked = profile.lastCheckedAt else { return "尚未检测" }
        let names: [(StationCapability, String)] = [
            (.subscriptions, "订阅"), (.accountMetrics, "累计指标"),
            (.apiKeyDailyUsage, "当日用量"), (.concurrency, "并发"),
            (.usageHistory, "使用记录")
        ]
        let supported = names.filter { profile.capabilities.contains($0.0) }.map(\.1)
        return "已验证：\(supported.isEmpty ? "基础 Key 列表" : supported.joined(separator: "、")) · \(settingsTimeFormatter.string(from: checked))"
    }

    @objc private func addProfile() {
        let profile = StationProfile(name: "新站点", serviceURL: "", timezone: TimeZone.current.identifier)
        profiles.append(profile)
        loadProfile(profile)
        selectedTab = 0
        updateSelectedTab()
    }

    @objc private func changeProfile() {
        guard profilePopup.indexOfSelectedItem >= 0 else { return }
        let profile = profiles[profilePopup.indexOfSelectedItem]
        loadProfile(profile)
        guard store.profiles.contains(where: { $0.id == profile.id }) else { return }
        Task {
            do {
                try await store.selectProfile(profile.id)
            } catch {
                showError(error)
            }
        }
    }

    @objc private func deleteProfile() {
        guard profiles.count > 1 else { return }
        let profile = editingProfile
        let alert = NSAlert()
        alert.messageText = "删除站点“\(profile.name)”？"
        alert.informativeText = "该站点保存在本机的账号密码也会被删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard store.profiles.contains(where: { $0.id == profile.id }) else {
            profiles.removeAll { $0.id == profile.id }
            loadProfile(store.activeProfile ?? profiles[0])
            return
        }
        Task {
            do {
                try await store.deleteProfile(profile.id)
                profiles = store.profiles
                loadProfile(store.activeProfile ?? profiles[0])
            } catch { showError(error) }
        }
    }

    @objc private func testConnection() {
        testButton.isEnabled = false
        testButton.title = "检测中…"
        connectionLabel.stringValue = "正在验证登录和接口能力"
        Task {
            do {
                let result = try await store.testConnection(profile: profileFromControls(), credentials: enteredCredentials)
                subscriptions = result.subscriptions
                reloadSubscriptionPopup(selection: profileFromControls().subscriptionSelection)
                var checkedProfile = profileFromControls()
                checkedProfile.capabilities = result.capabilities
                checkedProfile.lastCheckedAt = result.checkedAt
                try await store.updateProfile(checkedProfile, credentials: enteredCredentials)
                editingProfile = store.activeProfile ?? checkedProfile
                profiles = store.profiles
                reloadProfilePopup()
                connectionLabel.stringValue = capabilitySummary(checkedProfile)
            } catch { connectionLabel.stringValue = error.localizedDescription }
            testButton.title = "测试连接"
            testButton.isEnabled = true
        }
    }

    @objc private func testLogin() {
        loginTestButton.isEnabled = false
        loginTestButton.title = "测试中…"
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.stringValue = "正在验证"
        Task {
            do {
                try await store.testLogin(profile: profileFromControls(), credentials: enteredCredentials)
                loginStatusLabel.textColor = .systemGreen
                loginStatusLabel.stringValue = "登录成功"
            } catch {
                loginStatusLabel.textColor = .systemRed
                loginStatusLabel.stringValue = error.localizedDescription
            }
            loginTestButton.title = "测试登录"
            loginTestButton.isEnabled = true
        }
    }

    @objc private func togglePasswordVisibility() {
        let shouldShow = visiblePasswordField.isHidden
        synchronizePasswordFields(from: shouldShow ? passwordField : visiblePasswordField)
        passwordField.isHidden = shouldShow
        visiblePasswordField.isHidden = !shouldShow
        passwordVisibilityButton.image = settingsSymbol(shouldShow ? "eye.slash" : "eye", pointSize: 12)
        passwordVisibilityButton.toolTip = shouldShow ? "隐藏密码" : "显示密码"
        view.window?.makeFirstResponder(shouldShow ? visiblePasswordField : passwordField)
    }

    private func persistProfileFromControls() {
        guard !isLoadingControls else { return }
        clearMessage()
        let profile = profileFromControls()
        let credentials = enteredCredentials
        let isStoredProfile = store.profiles.contains { $0.id == profile.id }
        if !isStoredProfile {
            let isComplete = !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !profile.serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !credentials.email.isEmpty
                && !credentials.password.isEmpty
            guard isComplete else { return }
        }
        Task {
            do {
                try await store.updateProfile(profile, credentials: credentials)
                editingProfile = store.activeProfile ?? profile
                profiles = store.profiles
                reloadProfilePopup()
                connectionLabel.stringValue = capabilitySummary(editingProfile)
            } catch {
                showError(error)
            }
        }
    }

    private func persistPreferences() {
        guard !isLoadingControls else { return }
        do {
            try store.updatePreferences(UserPreferences(
                refreshInterval: UserPreferences.normalizedRefreshInterval(refreshField.doubleValue),
                launchAtLogin: launchAtLoginSwitch.state == .on,
                showAPIKeyDetails: showAPIKeyDetailsSwitch.state == .on,
                showMetricCards: showMetricCardsSwitch.state == .on,
                showUsageHistory: showUsageHistorySwitch.state == .on
            ))
            clearMessage()
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let launchError = store.settingsMessage.flatMap {
            $0.hasPrefix("开机启动设置失败") ? $0 : nil
        }
        messageLabel.stringValue = launchError ?? error.localizedDescription
        messageLabel.isHidden = false
        statusBarHeightConstraint?.constant = 30
        selectTab(at: error is StationProfileError ? 0 : 1)
    }

    private func clearMessage() {
        messageLabel.isHidden = true
        statusBarHeightConstraint?.constant = 0
    }

    @objc private func stepRefreshInterval() {
        refreshField.integerValue = refreshStepper.integerValue
        persistPreferences()
    }
    @objc private func preferenceControlChanged() { persistPreferences() }
    @objc private func profileSelectionChanged() { persistProfileFromControls() }
    @objc private func selectTab(_ sender: SettingsTabButton) { selectTab(at: sender.tag) }
    private func selectTab(at index: Int) { selectedTab = index; updateSelectedTab() }

    private func updateSelectedTab() {
        for (index, button) in tabButtons.enumerated() { button.isSelectedTab = index == selectedTab }
        for (index, tab) in tabViews.enumerated() { tab.isHidden = index != selectedTab }
    }

    @objc private func checkForUpdates() {
        updateButton.isEnabled = false
        updateButton.title = "检查中…"
        updateStatusLabel.stringValue = "正在检查"
        Task {
            do {
                switch try await updater.checkForUpdate(currentVersion: AppVersionInfo.version) {
                case .upToDate(let version): updateStatusLabel.stringValue = "已是最新版本 \(version)"
                case .available(let release):
                    updateButton.title = "下载中…"
                    updateStatusLabel.stringValue = "正在下载 \(release.version)"
                    let fileURL = try await updater.download(release)
                    updateStatusLabel.stringValue = "已下载 \(release.version)"
                    NSWorkspace.shared.open(fileURL)
                }
            } catch { updateStatusLabel.stringValue = error.localizedDescription }
            updateButton.title = "检查更新"
            updateButton.isEnabled = true
        }
    }

}

@MainActor
private final class SettingsTabButton: NSButton {
    var isSelectedTab = false { didSet { updateAppearance() } }
    private let iconView: NSImageView
    private let titleLabel: NSTextField

    init(title: String, symbolName: String) {
        iconView = NSImageView(image: settingsSymbol(symbolName, pointSize: 17))
        titleLabel = settingsLabel(title, size: 11)
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)
        ])
        let content = NSStackView(views: [iconView, titleLabel])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 58), heightAnchor.constraint(equalToConstant: 44),
            content.centerXAnchor.constraint(equalTo: centerXAnchor), content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelectedTab else { return }
        let fill = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        fill.fill()
        let scale = window?.backingScaleFactor ?? 2
        let width = 1 / scale
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: 8, yRadius: 8)
        border.lineWidth = width
        NSColor.controlAccentColor.withAlphaComponent(0.22).setStroke()
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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
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

private let settingsTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
}()

@MainActor
private func settingsLabel(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
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
    separator.alphaValue = 0.32
    return separator
}

@MainActor
private func settingsSymbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
}
