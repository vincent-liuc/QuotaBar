import AppKit

@MainActor
final class UsagePopoverController: NSViewController {
    private let store: UsageStore
    private let showPreferences: (SettingsTab) -> Void
    private let bodyContainer = NSView()
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let headerUpdatedLabel = NSTextField(labelWithString: "")
    private let stationSwitcher: StationSwitcherControl
    private var bodyView: NSView?
    private var stationSwitchBodyHeight: CGFloat?
    private var renderedPhase: UsagePhase?
    private var renderedProfileID: UUID?
    private var renderedSnapshot: UsageSnapshot?
    private var renderedPreferences: UserPreferences?
    private var bodyTransitionID = 0

    init(store: UsageStore, showPreferences: @escaping (SettingsTab) -> Void) {
        self.store = store
        self.showPreferences = showPreferences
        stationSwitcher = StationSwitcherControl()
        super.init(nibName: nil, bundle: nil)
        stationSwitcher.onSelect = { [weak self] profileID in
            self?.selectStation(profileID)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()

        [header, bodyContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 332),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            bodyContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        refreshContent()
    }

    func refreshContent() {
        guard isViewLoaded else { return }
        let bodyNeedsUpdate = bodyView == nil
            || renderedPhase != store.phase
            || renderedProfileID != store.activeProfileID
            || renderedSnapshot != store.snapshot
            || renderedPreferences != store.preferences

        if bodyNeedsUpdate {
            let previousBody = bodyView
            let previousPhase = renderedPhase
            let shouldPreserveScroll = renderedProfileID == store.activeProfileID
                && renderedPhase == .ready
                && store.phase == .ready
            let previousScrollPositions = shouldPreserveScroll
                ? scrollPositions(in: previousBody)
                : [:]
            let windowTopEdge = view.window?.frame.maxY
            let retainedBodyHeight = stationSwitchBodyHeight
            let isRetainingStationSwitchHeight = retainedBodyHeight != nil && store.phase == .loading
            let nextBody = UsageContentView(
                store: store,
                showPreferences: showPreferences,
                loadingHeight: isRetainingStationSwitchHeight ? retainedBodyHeight : nil
            )
            nextBody.translatesAutoresizingMaskIntoConstraints = false
            nextBody.alphaValue = previousBody != nil && (previousPhase == .loading || store.phase == .loading) ? 0 : 1
            bodyContainer.subviews
                .filter { $0 !== previousBody }
                .forEach { $0.removeFromSuperview() }
            bodyContainer.addSubview(nextBody)
            NSLayoutConstraint.activate([
                nextBody.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                nextBody.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                nextBody.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                nextBody.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
            ])
            bodyView = nextBody
            renderedPhase = store.phase
            renderedProfileID = store.activeProfileID
            renderedSnapshot = store.snapshot
            renderedPreferences = store.preferences

            let shouldAnimateBody = previousBody != nil
                && (previousPhase == .loading || store.phase == .loading)
            bodyTransitionID += 1
            let transitionID = bodyTransitionID
            if shouldAnimateBody {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    previousBody?.animator().alphaValue = 0
                    nextBody.animator().alphaValue = 1
                } completionHandler: { [weak self, weak previousBody, weak nextBody] in
                    Task { @MainActor [weak self, weak previousBody, weak nextBody] in
                        guard let self,
                              self.bodyTransitionID == transitionID,
                              self.bodyView === nextBody else { return }
                        previousBody?.removeFromSuperview()
                    }
                }
            } else {
                previousBody?.removeFromSuperview()
            }

            nextBody.layoutSubtreeIfNeeded()
            restoreScrollPositions(previousScrollPositions, in: nextBody)
            let bodyHeight = nextBody.fittingSize.height
            if isRetainingStationSwitchHeight, let retainedBodyHeight {
                preferredContentSize = NSSize(width: 332, height: max(retainedBodyHeight + 32, 150))
            } else {
                stationSwitchBodyHeight = nil
                preferredContentSize = NSSize(width: 332, height: max(bodyHeight + 32, 150))
            }
            restorePopoverTopEdge(windowTopEdge)
        }

        stationSwitcher.update(
            profiles: store.profiles,
            activeProfileID: store.activeProfileID
        )
        refreshButton.image = symbol(store.isRefreshing ? "hourglass" : "arrow.clockwise")
        refreshButton.isEnabled = !store.isRefreshing
        settingsButton.image = symbol("list.bullet", pointSize: 14)
        settingsButton.toolTip = "菜单"
        headerUpdatedLabel.stringValue = store.snapshot.map {
            "更新于 \(timeFormatter.string(from: $0.fetchedAt))"
        } ?? ""
    }

    private func scrollPositions(in root: NSView?) -> [String: NSPoint] {
        guard let root else { return [:] }
        var positions: [String: NSPoint] = [:]

        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               let identifier = scroll.identifier?.rawValue {
                positions[identifier] = scroll.contentView.bounds.origin
            }
            view.subviews.forEach(visit)
        }

        visit(root)
        return positions
    }

    private func restoreScrollPositions(_ positions: [String: NSPoint], in root: NSView) {
        guard !positions.isEmpty else { return }

        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               let identifier = scroll.identifier?.rawValue,
               let position = positions[identifier] {
                scroll.layoutSubtreeIfNeeded()
                let documentHeight = scroll.documentView?.bounds.height ?? 0
                let viewportHeight = scroll.contentView.bounds.height
                let maxY = max(0, documentHeight - viewportHeight)
                let origin = NSPoint(
                    x: position.x,
                    y: min(max(position.y, 0), maxY)
                )
                scroll.contentView.setBoundsOrigin(origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            view.subviews.forEach(visit)
        }

        visit(root)
    }

    private func restorePopoverTopEdge(_ topEdge: CGFloat?, deferToNextRunLoop: Bool = true) {
        guard let topEdge, let window = view.window, window.isVisible else { return }
        var frame = window.frame
        let delta = topEdge - frame.maxY
        guard abs(delta) > 0.25 else { return }
        frame.origin.y += delta
        window.setFrameOrigin(frame.origin)
        if deferToNextRunLoop {
            DispatchQueue.main.async { [weak self] in
                self?.restorePopoverTopEdge(topEdge, deferToNextRunLoop: false)
            }
        }
    }

    private func makeHeader() -> NSView {
        configureIconButton(refreshButton, symbolName: "arrow.clockwise", toolTip: "立即刷新")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        configureIconButton(settingsButton, symbolName: "list.bullet", toolTip: "菜单")
        settingsButton.target = self
        settingsButton.action = #selector(showApplicationMenu)

        let actions = NSStackView(views: [refreshButton, settingsButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2

        headerUpdatedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        headerUpdatedLabel.textColor = .secondaryLabelColor
        headerUpdatedLabel.lineBreakMode = .byClipping
        headerUpdatedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        let stack = NSStackView(views: [stationSwitcher, spacer, headerUpdatedLabel, actions])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 7)
        return stack
    }

    private func selectStation(_ profileID: UUID) {
        guard profileID != store.activeProfileID else { return }
        let currentBodyHeight = preferredContentSize.height - 32
        if currentBodyHeight > 0 {
            stationSwitchBodyHeight = currentBodyHeight
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.selectProfile(profileID)
            } catch StationProfileError.missingCredentials {
                stationSwitchBodyHeight = nil
                showPreferences(.account)
            } catch {
                stationSwitchBodyHeight = nil
                NSSound.beep()
            }
        }
    }

    @objc private func refresh() {
        store.refreshNow()
    }

    @objc private func openPreferences() {
        showPreferences(.general)
    }

    @objc private func showApplicationMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置", action: #selector(openPreferences), keyEquivalent: ",")
        settings.image = symbol("gearshape", pointSize: 13)
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 QuotaBar", action: #selector(quitApplication), keyEquivalent: "q")
        quit.image = symbol("power", pointSize: 13)
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settingsButton.bounds.minY - 2), in: settingsButton)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
private final class UsageContentView: NSView {
    private let showPreferences: (SettingsTab) -> Void
    private let loadingHeight: CGFloat?

    init(
        store: UsageStore,
        showPreferences: @escaping (SettingsTab) -> Void,
        loadingHeight: CGFloat? = nil
    ) {
        self.showPreferences = showPreferences
        self.loadingHeight = loadingHeight
        super.init(frame: .zero)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if store.phase == .needsConfiguration {
            content.addArrangedSubview(panel(makeConfigurationGuide(store.configurationProgress)))
        } else if let snapshot = store.snapshot {
            content.addArrangedSubview(makeDashboardPanel(
                snapshot,
                preferences: store.preferences,
                timezone: store.activeProfile?.timezone ?? TimeZone.current.identifier,
                stationKind: store.activeProfile?.kind ?? .sub2API
            ))
        } else if store.phase == .loading {
            content.addArrangedSubview(makeLoadingView(height: loadingHeight))
        }

        if case .failed(let issue) = store.phase {
            content.addArrangedSubview(panel(makeErrorView(issue)))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeUsageRow(_ snapshot: UsageSnapshot, stationKind: StationKind) -> NSView {
        let ring = LargeUsageRingView(snapshot: snapshot)
        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 82),
            ring.heightAnchor.constraint(equalToConstant: 82)
        ])
        let quotaKind = snapshot.weeklyUsage?.kind ?? .weekly
        var ringViews: [NSView] = [ring]
        if !(stationKind == .newAPI && quotaKind == .accountPool) {
            let resetTitle: String
            switch quotaKind {
            case .accountPool:
                resetTitle = "账户额度"
            case .tokenPool:
                resetTitle = "限额令牌汇总"
            case .weekly:
                resetTitle = weeklyResetTitle(snapshot.weeklyUsage?.resetAt)
            }
            let reset = label(resetTitle, size: 9, color: .tertiaryLabelColor)
            reset.alignment = .center
            reset.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            reset.toolTip = snapshot.weeklyUsage?.resetAt.map { "下次周额度重置：\(resetDateFormatter.string(from: $0))" }
            reset.widthAnchor.constraint(equalToConstant: 82).isActive = true
            ringViews.append(reset)
        }
        let ringGroup = NSStackView(views: ringViews)
        ringGroup.orientation = .vertical
        ringGroup.alignment = .centerX
        ringGroup.spacing = 1

        let metricTitles: (total: String, used: String, remaining: String)
        switch quotaKind {
        case .accountPool:
            metricTitles = ("账户总量", "历史消耗", "账户余额")
        case .tokenPool:
            metricTitles = ("令牌总额", "令牌已用", "令牌剩余")
        case .weekly:
            metricTitles = ("每周总量", "本周用量", "本周剩余")
        }
        let metrics = NSStackView(views: [
            metricRow(metricTitles.total, value: snapshot.total, emphasized: false),
            metricRow(metricTitles.used, value: snapshot.used, emphasized: true),
            metricRow(metricTitles.remaining, value: snapshot.remaining, emphasized: false)
        ])
        metrics.orientation = .vertical
        metrics.alignment = .leading
        metrics.spacing = 9

        let row = NSStackView(views: [ringGroup, metrics])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.widthAnchor.constraint(equalToConstant: 286).isActive = true
        return row
    }

    private func metricRow(_ title: String, value: Double, emphasized: Bool) -> NSView {
        let titleLabel = label(title, size: 12, color: .secondaryLabelColor)
        let valueLabel = label(currency(value), size: 13, weight: emphasized ? .semibold : .regular)
        valueLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: 13,
            weight: emphasized ? .semibold : .regular
        )
        let spacer = NSView()
        let row = NSStackView(views: [titleLabel, spacer, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.widthAnchor.constraint(equalToConstant: 191).isActive = true
        return row
    }

    private func makeDashboardPanel(
        _ snapshot: UsageSnapshot,
        preferences: UserPreferences,
        timezone: String,
        stationKind: StationKind
    ) -> NSView {
        let sections = NSStackView()
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 0

        func appendSection(_ view: NSView) {
            if !sections.arrangedSubviews.isEmpty {
                sections.addArrangedSubview(sectionSeparator())
            }
            sections.addArrangedSubview(view)
        }

        if stationKind != .newAPI, preferences.showMetricCards, let accountMetrics = snapshot.accountMetrics {
            appendSection(makeMetricCards(accountMetrics))
        }
        if preferences.showSubscriptionQuota {
            if snapshot.hasWeeklyUsage {
                appendSection(makeUsageRow(snapshot, stationKind: stationKind))
            } else {
                appendSection(unavailableRow(
                    stationKind == .newAPI ? "当前站点没有设置限额令牌" : "当前站点没有可用的周订阅额度"
                ))
            }
        }
        if preferences.showDailyUsage, let dailyUsage = snapshot.dailyUsage {
            appendSection(makeDailyUsageRow(dailyUsage))
        }
        if preferences.showAPIKeyDetails {
            appendSection(makeKeyDetails(snapshot.keys))
        }
        if preferences.showUsageHistory, let records = snapshot.usageRecords {
            appendSection(makeUsageHistory(records, timezone: timezone))
        }
        return panel(sections)
    }

    private func makeDailyUsageRow(_ usage: DailyUsage) -> NSView {
        let title = label("每日用量", size: 11, weight: .semibold)
        let progress = ThinQuotaProgressView(progress: usage.progress)
        progress.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: 286),
            progress.heightAnchor.constraint(equalToConstant: 4)
        ])
        let quota = label(
            "额度：\(currency(usage.used)) / \(currency(usage.total))",
            size: 10,
            color: .secondaryLabelColor
        )
        quota.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let details = NSStackView(views: [quota, progress])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        let stack = NSStackView(views: [title, details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.widthAnchor.constraint(equalToConstant: 286).isActive = true
        return stack
    }

    private func makeMetricCards(_ metrics: AccountMetrics) -> NSView {
        let tokens = metricCard(
            title: metrics.tokensPeriod == .today ? "今日 Token" : "累计 Token",
            value: compactTokenCount(metrics.totalTokens),
            symbolName: "sum",
            tint: .systemIndigo
        )
        let cost = metricCard(
            title: metrics.balance == nil ? "累计消费" : "历史消耗",
            value: currency(metrics.totalActualCost),
            symbolName: "dollarsign.circle.fill",
            tint: .systemGreen
        )
        var cards = [tokens, cost]
        if let balance = metrics.balance {
            cards.insert(metricCard(title: "账户余额", value: currency(balance), symbolName: "wallet.pass.fill", tint: .systemOrange), at: 0)
        }
        if let requestCount = metrics.requestCount {
            cards.append(metricCard(title: "请求次数", value: String(requestCount), symbolName: "arrow.up.right", tint: .systemBlue))
        }
        let rows = stride(from: 0, to: cards.count, by: 2).map { start -> NSView in
            let rowCards = Array(cards[start..<min(start + 2, cards.count)])
            let row = NSStackView(views: rowCards)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 10
            row.widthAnchor.constraint(equalToConstant: 286).isActive = true
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func metricCard(title: String, value: String, symbolName: String, tint: NSColor) -> NSView {
        let icon = NSImageView(image: symbol(symbolName, pointSize: 13))
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])

        let titleLabel = label(title, size: 10, color: .secondaryLabelColor)
        let valueLabel = label(value, size: 15, weight: .semibold)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let text = NSStackView(views: [titleLabel, valueLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let content = NSStackView(views: [icon, text])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 9
        return metricTile(content)
    }

    private func makeKeyDetails(_ keys: [UsageKey]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        if keys.isEmpty {
            let empty = label("暂无 API Key", size: 11, color: .secondaryLabelColor)
            empty.alignment = .center
            empty.widthAnchor.constraint(equalToConstant: 286).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 48).isActive = true
            stack.addArrangedSubview(empty)
        } else {
            for key in keys {
                stack.addArrangedSubview(makeKeyRow(key))
            }
        }

        let listView: NSView
        let estimatedHeight = keys.reduce(CGFloat(0)) { partial, key in
            partial + (key.quota > 0 ? 56 : 27)
        } + CGFloat(max(keys.count - 1, 0) * 2)
        if estimatedHeight <= 172 {
            listView = stack
        } else {
            let documentView = FlippedView()
            documentView.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: documentView.topAnchor),
                stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
                documentView.widthAnchor.constraint(equalToConstant: 286)
            ])

            let scroll = NSScrollView()
            scroll.identifier = NSUserInterfaceItemIdentifier("api-key-details")
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = documentView
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalToConstant: 286),
                scroll.heightAnchor.constraint(equalToConstant: 172)
            ])
            listView = scroll
        }

        return listView
    }

    private func makeKeyRow(_ key: UsageKey) -> NSView {
        let leadingViews: [NSView]
        if key.concurrency > 0 {
            let concurrency = label("● \(key.concurrency)", size: 10, weight: .medium, color: .systemGreen)
            concurrency.toolTip = "当前并发 \(key.concurrency)"
            concurrency.setContentCompressionResistancePriority(.required, for: .horizontal)
            leadingViews = [concurrency]
        } else {
            leadingViews = []
        }
        let name = label(key.name, size: 11, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let nameViews: [NSView] = key.group.map {
            let group = label("\($0)", size: 9, color: .tertiaryLabelColor)
            group.lineBreakMode = .byTruncatingTail
            group.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return group
        }.map { [name, $0] } ?? [name]
        let todayValue = key.todayActualCost.map(currency) ?? "--"
        let value = label("今日 \(todayValue)",
                          size: 11,
                          color: .secondaryLabelColor)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        let top = NSStackView(views: nameViews + leadingViews + [spacer, value])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 6

        top.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        top.widthAnchor.constraint(equalToConstant: 286).isActive = true

        guard key.quota > 0 else {
            top.heightAnchor.constraint(equalToConstant: 27).isActive = true
            return top
        }

        let quota = label(
            "额度：\(currency(key.quotaUsed)) / \(currency(key.quota))",
            size: 10,
            color: .secondaryLabelColor
        )
        quota.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let progress = ThinQuotaProgressView(progress: key.progress)
        progress.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: 286),
            progress.heightAnchor.constraint(equalToConstant: 4)
        ])
        let detail = NSStackView(views: [quota, progress])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 4

        let row = NSStackView(views: [top, detail])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 1
        row.widthAnchor.constraint(equalToConstant: 286).isActive = true
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 3, right: 0)
        return row
    }

    private func makeUsageHistory(_ records: [UsageRecord], timezone: String) -> NSView {
        let title = label("使用记录", size: 11, weight: .semibold)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false

        if records.isEmpty {
            let empty = label("暂无使用记录", size: 11, color: .secondaryLabelColor)
            empty.alignment = .center
            empty.widthAnchor.constraint(equalToConstant: 286).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 44).isActive = true
            rows.addArrangedSubview(empty)
        } else {
            records.prefix(UsageSnapshot.maximumUsageRecords).forEach {
                rows.addArrangedSubview(makeUsageHistoryRow($0, timezone: timezone))
            }
        }

        let list: NSView
        let listHeight = CGFloat(records.prefix(UsageSnapshot.maximumUsageRecords).count * 39)
        if listHeight <= 195 {
            list = rows
        } else {
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(rows)
            NSLayoutConstraint.activate([
                rows.topAnchor.constraint(equalTo: document.topAnchor),
                rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                document.widthAnchor.constraint(equalToConstant: 286)
            ])
            let scroll = NSScrollView()
            scroll.identifier = NSUserInterfaceItemIdentifier("usage-history")
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = document
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalToConstant: 286),
                scroll.heightAnchor.constraint(equalToConstant: 195)
            ])
            list = scroll
        }

        let section = NSStackView(views: [title, list])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        return section
    }

    private func makeUsageHistoryRow(_ record: UsageRecord, timezone: String) -> NSView {
        let key = label(record.apiKeyName, size: 10, weight: .medium)
        key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let model = label(record.model, size: 10, color: .secondaryLabelColor)
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cost = label(usageCost(record.actualCost), size: 10, weight: .medium)
        cost.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        cost.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [key, model, NSView(), cost])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 6

        let effort = label(reasoningEffortTitle(record.reasoningEffort), size: 9, color: .tertiaryLabelColor)
        let date = label(usageDate(record.createdAt, timezone: timezone), size: 9, color: .tertiaryLabelColor)
        date.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let bottom = NSStackView(views: [effort, NSView(), date])
        bottom.orientation = .horizontal
        bottom.alignment = .firstBaseline

        let row = NSStackView(views: [top, bottom])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        row.widthAnchor.constraint(equalToConstant: 286).isActive = true
        row.heightAnchor.constraint(equalToConstant: 37).isActive = true
        return row
    }

    private func unavailableRow(_ message: String) -> NSView {
        let container = NSView()
        let text = label(message, size: 11, color: .secondaryLabelColor)
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(text)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 286),
            container.heightAnchor.constraint(equalToConstant: 54),
            text.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            text.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            text.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])
        return container
    }

    private func panel(_ content: NSView) -> NSView {
        let wrapper = PopoverPanelView(cornerRadius: 11)

        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(effect)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.24).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)

        let border = PopoverBorderView(cornerRadius: 11)
        border.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(border)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalToConstant: 316),
            effect.topAnchor.constraint(equalTo: wrapper.topAnchor),
            effect.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -15),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            border.topAnchor.constraint(equalTo: wrapper.topAnchor),
            border.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            border.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])
        return wrapper
    }

    private func metricTile(_ content: NSView) -> NSView {
        let tile = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: tile.topAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -9),
            content.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -4)
        ])
        return tile
    }

    private func sectionSeparator() -> NSView {
        let container = HairlineSeparatorView()
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 286),
            container.heightAnchor.constraint(equalToConstant: 13)
        ])
        return container
    }

    private func makeLoadingView(height: CGFloat? = nil) -> NSView {
        let container = NSView()
        let animation = LoadingCatAnimationView()
        animation.translatesAutoresizingMaskIntoConstraints = false
        let text = label("正在读取用量", size: 12, color: .secondaryLabelColor)
        text.alignment = .center
        let stack = NSStackView(views: [animation, text])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 316),
            container.heightAnchor.constraint(equalToConstant: max(height ?? 110, 110)),
            animation.widthAnchor.constraint(equalToConstant: 88),
            animation.heightAnchor.constraint(equalToConstant: 24),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func makeConfigurationGuide(_ progress: ConfigurationProgress) -> NSView {
        let title = label("仅需2步开始使用", size: 13, weight: .semibold)
        let subtitle = label("完成配置后即可查看 Dashboard", size: 10, color: .secondaryLabelColor)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let steps = NSStackView(views: [
            configurationStep(
                number: 1,
                title: "完成站点配置",
                detail: "填写并验证 Sub2API 兼容站点",
                isComplete: progress.stationIsValid,
                tab: .station
            ),
            configurationStep(
                number: 2,
                title: "填写账户信息",
                detail: "填写登录账号和登录密码",
                isComplete: progress.accountIsValid,
                tab: .account
            )
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 6

        let stack = NSStackView(views: [heading, steps])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.widthAnchor.constraint(equalToConstant: 286).isActive = true
        return stack
    }

    private func configurationStep(
        number: Int,
        title: String,
        detail: String,
        isComplete: Bool,
        tab: SettingsTab
    ) -> NSView {
        let status = NSImageView(image: symbol(isComplete ? "checkmark.circle.fill" : "\(number).circle.fill", pointSize: 17))
        status.contentTintColor = isComplete ? .systemGreen : .controlAccentColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let titleLabel = label(title, size: 12, weight: .medium)
        let detailLabel = label(isComplete ? "已完成" : detail, size: 10, color: isComplete ? .systemGreen : .secondaryLabelColor)
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let arrow = NSImageView(image: symbol("chevron.right", pointSize: 10))
        arrow.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: [status, labels, NSView(), arrow])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.36).cgColor
        row.layer?.cornerRadius = 7
        row.widthAnchor.constraint(equalToConstant: 286).isActive = true
        let button = DashboardActionButton(contentView: row) { [weak self] in self?.showPreferences(tab) }
        button.setAccessibilityLabel("\(title)，\(isComplete ? "已完成" : "未完成")，打开设置")
        return button
    }

    private func makeErrorView(_ issue: DashboardIssue) -> NSView {
        let icon = NSImageView(image: symbol("exclamationmark.triangle.fill", pointSize: 12))
        icon.contentTintColor = .systemOrange
        let text = wrappingLabel(issue.message, size: 11, color: .labelColor)
        var views: [NSView] = [icon, text, NSView()]
        if issue.settingsTab != nil {
            let arrow = NSImageView(image: symbol("chevron.right", pointSize: 10))
            arrow.contentTintColor = .secondaryLabelColor
            views.append(arrow)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
        stack.layer?.cornerRadius = 6
        stack.widthAnchor.constraint(equalToConstant: 286).isActive = true
        guard let tab = issue.settingsTab else { return stack }
        let button = DashboardActionButton(contentView: stack) { [weak self] in self?.showPreferences(tab) }
        button.setAccessibilityLabel("\(issue.message)，打开设置")
        return button
    }

}

@MainActor
private final class DashboardActionButton: NSButton {
    private let handler: () -> Void
    private let hostedContentView: NSView

    init(contentView: NSView, handler: @escaping () -> Void) {
        self.handler = handler
        hostedContentView = contentView
        super.init(frame: .zero)
        title = ""
        isBordered = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        target = self
        action = #selector(activate)
    }

    override var intrinsicContentSize: NSSize {
        hostedContentView.fittingSize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func activate() { handler() }
}

@MainActor
private final class StationSwitcherControl: NSControl {
    var onSelect: ((UUID) -> Void)?

    private var profiles: [StationProfile] = []
    private var activeProfileID: UUID?
    private var isHovered = false
    private var trackingAreaReference: NSTrackingArea?
    private let menuPopover = NSPopover()

    override var intrinsicContentSize: NSSize {
        let name = profiles.first(where: { $0.id == activeProfileID })?.name ?? "当前站点"
        let width = min(max(measuredNameWidth(name) + 34, 84), 148)
        return NSSize(width: width, height: 23)
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled, menuPopover.isShown { menuPopover.performClose(nil) }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.popUpButton)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(profiles: [StationProfile], activeProfileID: UUID?) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        isEnabled = profiles.count > 1
        updateAccessibility()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, profiles.count > 1 else { return }
        if menuPopover.isShown {
            menuPopover.performClose(nil)
        } else {
            showMenu()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = bounds.height / 2
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let fillColor: NSColor = isEnabled && isHovered
            ? .controlAccentColor.withAlphaComponent(0.12)
            : .controlBackgroundColor.withAlphaComponent(isEnabled ? 0.58 : 0.35)
        fillColor.setFill()
        pill.fill()

        let scale = window?.backingScaleFactor ?? 2
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5 / scale, dy: 0.5 / scale), xRadius: radius, yRadius: radius)
        border.lineWidth = 1 / scale
        (isEnabled ? NSColor.separatorColor.withAlphaComponent(0.58) : NSColor.separatorColor.withAlphaComponent(0.32)).setStroke()
        border.stroke()

        let name = profiles.first(where: { $0.id == activeProfileID })?.name ?? "当前站点"
        let textColor: NSColor = isEnabled ? .labelColor : .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let availableWidth = bounds.width - (isEnabled ? 28 : 16)
        let displayName = truncatedName(name, font: font, maxWidth: availableWidth)
        let textSize = displayName.size(withAttributes: [.font: font])
        let textWidth = min(textSize.width, availableWidth)
        let textRect = NSRect(
            x: isEnabled ? 9 : (bounds.width - textWidth) / 2,
            y: (bounds.height - textSize.height) / 2 + 0.5,
            width: textWidth,
            height: textSize.height
        )
        displayName.draw(in: textRect, withAttributes: [.font: font, .foregroundColor: textColor])

        if isEnabled {
            let chevron = NSBezierPath()
            let centerX = bounds.width - 13
            let centerY = bounds.midY + 0.5
            chevron.move(to: NSPoint(x: centerX - 3, y: centerY + 1.5))
            chevron.line(to: NSPoint(x: centerX, y: centerY - 1.5))
            chevron.line(to: NSPoint(x: centerX + 3, y: centerY + 1.5))
            chevron.lineWidth = 1.1
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            (isHovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setStroke()
            chevron.stroke()
        }
    }

    private func showMenu() {
        let controller = StationSwitcherMenuViewController(
            profiles: profiles,
            activeProfileID: activeProfileID,
            onSelect: { [weak self] profileID in
                self?.menuPopover.performClose(nil)
                self?.onSelect?(profileID)
            }
        )
        menuPopover.appearance = effectiveAppearance
        menuPopover.contentViewController = controller
        menuPopover.behavior = .transient
        menuPopover.animates = true
        menuPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func updateAccessibility() {
        let name = profiles.first(where: { $0.id == activeProfileID })?.name ?? "当前站点"
        setAccessibilityLabel("当前站点：\(name)")
        setAccessibilityHelp(isEnabled ? "切换站点" : "仅配置一个站点，无法切换")
        setAccessibilityRole(.popUpButton)
    }

    private func measuredNameWidth(_ name: String) -> CGFloat {
        name.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
    }

    private func truncatedName(_ name: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard name.size(withAttributes: [.font: font]).width > maxWidth else { return name }
        var result = name
        while !result.isEmpty && (result + "…").size(withAttributes: [.font: font]).width > maxWidth {
            result.removeLast()
        }
        return result.isEmpty ? "…" : result + "…"
    }
}

@MainActor
private final class StationSwitcherMenuViewController: NSViewController {
    private let profiles: [StationProfile]
    private let activeProfileID: UUID?
    private let onSelect: (UUID) -> Void

    init(profiles: [StationProfile], activeProfileID: UUID?, onSelect: @escaping (UUID) -> Void) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = StationSwitcherMenuView(frame: .zero)
        root.onSelect = onSelect
        root.configure(profiles: profiles, activeProfileID: activeProfileID)
        view = root
        preferredContentSize = root.intrinsicContentSize
    }
}

@MainActor
private final class StationSwitcherMenuView: NSVisualEffectView {
    var onSelect: ((UUID) -> Void)?

    private var rows: [StationSwitcherRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: CGFloat(max(rows.count, 1)) * 36 + 12)
    }

    func configure(profiles: [StationProfile], activeProfileID: UUID?) {
        rows.forEach { $0.removeFromSuperview() }
        rows = profiles.map { profile in
            let row = StationSwitcherRow(profile: profile, isSelected: profile.id == activeProfileID)
            row.onSelect = { [weak self] id in self?.onSelect?(id) }
            addSubview(row)
            return row
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y = bounds.height - 6
        for row in rows {
            y -= 32
            row.frame = NSRect(x: 6, y: y, width: bounds.width - 12, height: 32)
            y -= 4
        }
    }

}

@MainActor
private final class StationSwitcherRow: NSControl {
    private let profile: StationProfile
    private let isSelected: Bool
    private var isHovered = false
    private var trackingAreaReference: NSTrackingArea?
    var onSelect: ((UUID) -> Void)?

    init(profile: StationProfile, isSelected: Bool) {
        self.profile = profile
        self.isSelected = isSelected
        super.init(frame: .zero)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(profile.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onSelect?(profile.id) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius: CGFloat = 7
        if isSelected || isHovered {
            (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }

        let font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        let color: NSColor = isSelected ? .controlAccentColor : .labelColor
        let textRect = NSRect(x: 12, y: (bounds.height - font.pointSize - 2) / 2, width: bounds.width - 36, height: font.pointSize + 4)
        profile.name.draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color])
        if isSelected {
            let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            check?.isTemplate = true
            NSColor.controlAccentColor.set()
            check?.draw(in: NSRect(x: bounds.width - 23, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

private final class PopoverPanelView: NSView {
    private let radius: CGFloat

    init(cornerRadius: CGFloat) {
        radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

}

private final class PopoverBorderView: NSView {
    private let radius: CGFloat

    init(cornerRadius: CGFloat) {
        radius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: radius,
            yRadius: radius
        )
        path.lineWidth = lineWidth
        NSColor.separatorColor.withAlphaComponent(0.38).setStroke()
        path.stroke()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

private final class HairlineSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        let y = floor(bounds.midY * scale) / scale + lineWidth / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX + 8, y: y))
        path.line(to: NSPoint(x: bounds.maxX - 8, y: y))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        dividerColor.setStroke()
        path.stroke()
    }

    private var dividerColor: NSColor {
        let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.04)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class LoadingCatAnimationView: NSView {
    private var animationTimer: Timer?
    private var phase = 0.0

    isolated deinit {
        animationTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            startAnimating()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let progress = phase.truncatingRemainder(dividingBy: 1)
        let catSize: CGFloat = 18
        let travel = max(bounds.width - catSize, 0)
        let catX = bounds.minX + travel * progress
        let stride = sin(progress * .pi * 8)
        let catY = bounds.midY - catSize / 2 + abs(stride) * 1.3
        let edgeFade = min(min(progress / 0.08, (1 - progress) / 0.08), 1)

        NSColor.secondaryLabelColor.withAlphaComponent(0.18 * edgeFade).setStroke()
        for (offset, length) in [(CGFloat(-3), CGFloat(7)), (CGFloat(2), CGFloat(5))] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: max(catX - length - 4, bounds.minX), y: bounds.midY + offset))
            line.line(to: NSPoint(x: max(catX - 4, bounds.minX), y: bounds.midY + offset))
            line.lineWidth = 1
            line.lineCapStyle = .round
            line.stroke()
        }

        let cat = StatusRingRenderer.image(
            progress: 0,
            phase: .loading,
            tailPhase: phase * .pi * 8
        )
        cat.draw(
            in: NSRect(x: catX, y: catY, width: catSize, height: catSize),
            from: .zero,
            operation: .sourceOver,
            fraction: edgeFade,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase = (self.phase + 0.018).truncatingRemainder(dividingBy: 1)
                self.needsDisplay = true
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

private final class ThinQuotaProgressView: NSView {
    private let progress: Double

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.secondaryLabelColor.withAlphaComponent(0.13).setFill()
        track.fill()
        guard progress > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: max(bounds.width * progress, bounds.height), height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        StatusRingRenderer.color(for: progress).setFill()
        fill.fill()
    }
}

@MainActor
private final class LargeUsageRingView: NSView {
    private let snapshot: UsageSnapshot

    init(snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 7, dy: 7)
        let background = NSBezierPath(ovalIn: rect)
        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setStroke()
        background.lineWidth = 8
        background.stroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: 90,
            endAngle: 90 - (360 * snapshot.progress),
            clockwise: true
        )
        StatusRingRenderer.color(for: snapshot.progress).setStroke()
        arc.lineWidth = 8
        arc.lineCapStyle = .round
        arc.stroke()

        let percent = "\(Int((snapshot.progress * 100).rounded()))%"
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        let percentSize = percent.size(withAttributes: percentAttributes)
        percent.draw(
            at: NSPoint(x: bounds.midX - percentSize.width / 2, y: bounds.midY - 3),
            withAttributes: percentAttributes
        )

        let caption = "已用"
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let captionSize = caption.size(withAttributes: captionAttributes)
        caption.draw(
            at: NSPoint(x: bounds.midX - captionSize.width / 2, y: bounds.midY - 18),
            withAttributes: captionAttributes
        )
    }
}

@MainActor
private func configureIconButton(_ button: NSButton, symbolName: String, toolTip: String) {
    button.image = symbol(symbolName)
    button.title = ""
    button.isBordered = false
    button.toolTip = toolTip
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 24),
        button.heightAnchor.constraint(equalToConstant: 24)
    ])
}

@MainActor
private func symbol(_ name: String, pointSize: CGFloat = 13) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) ?? NSImage()
}

@MainActor
private func label(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

@MainActor
private func wrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
    let field = label(text, size: size, color: color)
    field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func currency(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

private func usageCost(_ value: Double) -> String {
    String(format: "$%.4f", max(value, 0))
}

private func reasoningEffortTitle(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "推理：--" }
    let localized: String
    switch value.lowercased() {
    case "none": localized = "无"
    case "minimal": localized = "最小"
    case "low": localized = "低"
    case "medium": localized = "中"
    case "high": localized = "高"
    case "xhigh": localized = "极高"
    default: localized = value
    }
    return "推理：\(localized)"
}

private func usageDate(_ date: Date, timezone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: timezone) ?? .current
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func weeklyResetTitle(_ resetAt: Date?, now: Date = Date()) -> String {
    guard let resetAt else { return "" }
    let remaining = max(Int(resetAt.timeIntervalSince(now)), 0)
    let days = remaining / 86_400
    let hours = (remaining % 86_400) / 3_600
    if days > 0 { return "\(days)天\(hours)小时后重置" }
    let minutes = max((remaining % 3_600) / 60, 1)
    if hours > 0 { return "\(hours)小时\(minutes)分钟后重置" }
    return "\(minutes)分钟后重置"
}

private let resetDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

private func compactTokenCount(_ value: Int64) -> String {
    switch value {
    case 1_000_000_000...:
        return String(format: "%.1fB", Double(value) / 1_000_000_000)
    case 1_000_000...:
        return String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...:
        return String(format: "%.1fK", Double(value) / 1_000)
    default:
        return String(value)
    }
}
