import AppKit

@MainActor
final class UsagePopoverController: NSViewController {
    private let store: UsageStore
    private let showPreferences: () -> Void
    private let bodyContainer = NSView()
    private let headerIcon = NSImageView()
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let headerUpdatedLabel = NSTextField(labelWithString: "")
    private var bodyView: NSView?

    init(store: UsageStore, showPreferences: @escaping () -> Void) {
        self.store = store
        self.showPreferences = showPreferences
        super.init(nibName: nil, bundle: nil)
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
            header.heightAnchor.constraint(equalToConstant: 44),
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
        bodyView?.removeFromSuperview()

        let nextBody = UsageContentView(store: store)
        nextBody.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(nextBody)
        NSLayoutConstraint.activate([
            nextBody.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            nextBody.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            nextBody.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            nextBody.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
        ])
        bodyView = nextBody

        refreshButton.image = symbol(store.isRefreshing ? "hourglass" : "arrow.clockwise")
        refreshButton.isEnabled = !store.isRefreshing
        settingsButton.image = symbol("gearshape")
        settingsButton.toolTip = "偏好设置"
        headerUpdatedLabel.stringValue = store.snapshot.map {
            "更新于 \(timeFormatter.string(from: $0.fetchedAt))"
        } ?? ""
        headerIcon.image = StatusRingRenderer.image(
            progress: store.snapshot?.progress,
            phase: store.phase
        )

        nextBody.layoutSubtreeIfNeeded()
        let bodyHeight = nextBody.fittingSize.height
        preferredContentSize = NSSize(width: 332, height: max(bodyHeight + 44, 150))
    }

    private func makeHeader() -> NSView {
        headerIcon.image = StatusRingRenderer.image(
            progress: store.snapshot?.progress,
            phase: store.phase
        )
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerIcon.widthAnchor.constraint(equalToConstant: 20),
            headerIcon.heightAnchor.constraint(equalToConstant: 20)
        ])

        let title = label("OpenAI用量", size: 13, weight: .semibold)
        title.setContentHuggingPriority(.required, for: .horizontal)

        configureIconButton(refreshButton, symbolName: "arrow.clockwise", toolTip: "立即刷新")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        configureIconButton(settingsButton, symbolName: "gearshape", toolTip: "偏好设置")
        settingsButton.target = self
        settingsButton.action = #selector(openPreferences)

        let actions = NSStackView(views: [refreshButton, settingsButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2

        headerUpdatedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        headerUpdatedLabel.textColor = .secondaryLabelColor
        headerUpdatedLabel.lineBreakMode = .byClipping
        headerUpdatedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        let stack = NSStackView(views: [headerIcon, title, spacer, headerUpdatedLabel, actions])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 7)
        return stack
    }

    @objc private func refresh() {
        store.refreshNow()
    }

    @objc private func openPreferences() {
        showPreferences()
    }
}

@MainActor
private final class UsageContentView: NSView {
    init(store: UsageStore) {
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

        if let snapshot = store.snapshot {
            content.addArrangedSubview(makeDashboardPanel(snapshot, preferences: store.preferences))
        } else if store.phase == .loading {
            content.addArrangedSubview(makeLoadingView())
        }

        if case .failed(let message) = store.phase {
            content.addArrangedSubview(panel(makeErrorView(message)))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeUsageRow(_ snapshot: UsageSnapshot) -> NSView {
        let ring = LargeUsageRingView(snapshot: snapshot)
        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 82),
            ring.heightAnchor.constraint(equalToConstant: 82)
        ])

        let metrics = NSStackView(views: [
            metricRow("每周总量", value: snapshot.total, emphasized: false),
            metricRow("本周用量", value: snapshot.used, emphasized: true),
            metricRow("本周剩余", value: snapshot.remaining, emphasized: false)
        ])
        metrics.orientation = .vertical
        metrics.alignment = .leading
        metrics.spacing = 9

        let row = NSStackView(views: [ring, metrics])
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

    private func makeDashboardPanel(_ snapshot: UsageSnapshot, preferences: UserPreferences) -> NSView {
        let sections = NSStackView()
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 0
        sections.addArrangedSubview(makeUsageRow(snapshot))

        if preferences.showMetricCards {
            sections.addArrangedSubview(sectionSeparator())
            sections.addArrangedSubview(makeMetricCards(snapshot.accountMetrics))
        }
        if preferences.showAPIKeyDetails {
            sections.addArrangedSubview(sectionSeparator())
            sections.addArrangedSubview(makeKeyDetails(snapshot.keys))
        }
        return panel(sections)
    }

    private func makeMetricCards(_ metrics: AccountMetrics) -> NSView {
        let tokens = metricCard(
            title: "累计 Token",
            value: compactTokenCount(metrics.totalTokens),
            symbolName: "sum",
            tint: .systemIndigo
        )
        let cost = metricCard(
            title: "消费金额",
            value: currency(metrics.totalActualCost),
            symbolName: "dollarsign.circle.fill",
            tint: .systemGreen
        )
        let row = NSStackView(views: [tokens, cost])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 286).isActive = true
        return row
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
        if keys.count <= 6 {
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
        let concurrency: NSTextField
        if key.concurrency > 0 {
            concurrency = label("● \(key.concurrency)", size: 10, weight: .medium, color: .systemGreen)
            concurrency.toolTip = "当前并发 \(key.concurrency)"
        } else {
            concurrency = label("", size: 10)
        }
        concurrency.alignment = .left
        concurrency.widthAnchor.constraint(equalToConstant: 24).isActive = true
        concurrency.setContentCompressionResistancePriority(.required, for: .horizontal)
        let name = label(key.name, size: 11, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let value = label("今日 \(currency(key.todayActualCost))",
                          size: 11,
                          color: .secondaryLabelColor)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        let top = NSStackView(views: [concurrency, name, spacer, value])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 6

        top.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalToConstant: 286),
            top.heightAnchor.constraint(equalToConstant: 27)
        ])
        return top
    }

    private func panel(_ content: NSView) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.46).cgColor
        effect.shadow = NSShadow()
        effect.layer?.shadowColor = NSColor.black.cgColor
        effect.layer?.shadowOpacity = 0.09
        effect.layer?.shadowRadius = 2
        effect.layer?.shadowOffset = NSSize(width: 0, height: -1)
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            effect.widthAnchor.constraint(equalToConstant: 316),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -15),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12)
        ])
        return effect
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
        let container = NSView()
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.34).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 286),
            container.heightAnchor.constraint(equalToConstant: 25),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return container
    }

    private func makeLoadingView() -> NSView {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        let text = label("正在读取用量", size: 12, color: .secondaryLabelColor)
        let stack = NSStackView(views: [indicator, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 82, bottom: 28, right: 82)
        return stack
    }

    private func makeErrorView(_ message: String) -> NSView {
        let icon = NSImageView(image: symbol("exclamationmark.triangle.fill", pointSize: 12))
        icon.contentTintColor = .systemOrange
        let text = wrappingLabel(message, size: 11, color: .labelColor)
        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
        stack.layer?.cornerRadius = 6
        stack.widthAnchor.constraint(equalToConstant: 286).isActive = true
        return stack
    }

}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
