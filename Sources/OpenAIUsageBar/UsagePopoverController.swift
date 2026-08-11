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
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider = NSBox()
        divider.boxType = .separator

        [header, divider, bodyContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 326),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
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
        preferredContentSize = NSSize(width: 326, height: max(bodyHeight + 49, 150))
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

        headerUpdatedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        headerUpdatedLabel.textColor = .secondaryLabelColor
        headerUpdatedLabel.lineBreakMode = .byClipping
        headerUpdatedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        let stack = NSStackView(views: [headerIcon, title, actions, spacer, headerUpdatedLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
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
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 13, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let snapshot = store.snapshot {
            content.addArrangedSubview(makeUsageRow(snapshot))
            content.addArrangedSubview(separator())
            let keyDetails = makeKeyDetails(snapshot.keys)
            content.addArrangedSubview(keyDetails)
        } else if store.phase == .loading {
            content.addArrangedSubview(makeLoadingView())
        }

        if case .failed(let message) = store.phase {
            content.addArrangedSubview(makeErrorView(message))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeUsageRow(_ snapshot: UsageSnapshot) -> NSView {
        let ring = LargeUsageRingView(snapshot: snapshot)
        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 92),
            ring.heightAnchor.constraint(equalToConstant: 92)
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
        row.spacing = 18
        row.widthAnchor.constraint(equalToConstant: 294).isActive = true
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
        row.widthAnchor.constraint(equalToConstant: 184).isActive = true
        return row
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
            empty.widthAnchor.constraint(equalToConstant: 294).isActive = true
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
                documentView.widthAnchor.constraint(equalToConstant: 294)
            ])

            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = documentView
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalToConstant: 294),
                scroll.heightAnchor.constraint(equalToConstant: 172)
            ])
            listView = scroll
        }

        return listView
    }

    private func makeKeyRow(_ key: UsageKey) -> NSView {
        let dot = label("●", size: 8, color: .systemGreen)
        dot.toolTip = "已启用"
        let name = label(key.name, size: 11, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let value = label("今日 \(currency(key.todayActualCost))",
                          size: 11,
                          color: .secondaryLabelColor)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        let top = NSStackView(views: [dot, name, spacer, value])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 6

        top.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalToConstant: 294),
            top.heightAnchor.constraint(equalToConstant: 27)
        ])
        return top
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
        stack.widthAnchor.constraint(equalToConstant: 294).isActive = true
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

@MainActor
private func separator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    box.widthAnchor.constraint(equalToConstant: 294).isActive = true
    return box
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
