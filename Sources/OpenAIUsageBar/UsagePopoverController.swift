import AppKit

@MainActor
final class UsagePopoverController: NSViewController {
    private let store: UsageStore
    private let showPreferences: () -> Void
    private let bodyContainer = NSView()
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
        nextBody.layoutSubtreeIfNeeded()
        let bodyHeight = nextBody.fittingSize.height
        preferredContentSize = NSSize(width: 332, height: max(bodyHeight + 32, 150))
    }

    private func makeHeader() -> NSView {
        let title = label("Dashboard", size: 12, color: .secondaryLabelColor)
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
        let stack = NSStackView(views: [title, spacer, headerUpdatedLabel, actions])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 7)
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

        if preferences.showMetricCards, let accountMetrics = snapshot.accountMetrics {
            sections.addArrangedSubview(makeMetricCards(accountMetrics))
            sections.addArrangedSubview(sectionSeparator())
        }
        if snapshot.hasWeeklyUsage {
            sections.addArrangedSubview(makeUsageRow(snapshot))
        } else {
            sections.addArrangedSubview(unavailableRow("当前站点没有可用的周订阅额度"))
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
            title: "累计消费",
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
        let todayValue = key.todayActualCost.map(currency) ?? "--"
        let value = label("今日 \(todayValue)",
                          size: 11,
                          color: .secondaryLabelColor)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        let top = NSStackView(views: [name] + leadingViews + [spacer, value])
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

    private func unavailableRow(_ message: String) -> NSView {
        let text = label(message, size: 11, color: .secondaryLabelColor)
        text.alignment = .center
        text.widthAnchor.constraint(equalToConstant: 286).isActive = true
        text.heightAnchor.constraint(equalToConstant: 54).isActive = true
        return text
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
