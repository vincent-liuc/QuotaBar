import AppKit

@MainActor
enum StatusRingRenderer {
    private static let ringWidth: CGFloat = 2.5

    static func image(progress: Double?, phase: UsagePhase) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let ringRect = rect.insetBy(dx: 1.8, dy: 1.8)
            let background = NSBezierPath(ovalIn: ringRect)
            NSColor.secondaryLabelColor.withAlphaComponent(0.24).setStroke()
            background.lineWidth = ringWidth
            background.stroke()

            if let progress {
                drawArc(progress: progress, in: ringRect)
            } else {
                drawStateIndicator(for: phase, in: rect)
            }
            drawOpenAIMark(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawArc(progress: Double, in rect: NSRect) {
        guard progress > 0 else { return }
        let bounded = min(max(progress, 0), 1)
        let path = NSBezierPath()
        path.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: 90,
            endAngle: 90 - (360 * bounded),
            clockwise: true
        )
        color(for: bounded).setStroke()
        path.lineWidth = ringWidth
        path.lineCapStyle = .round
        path.stroke()
    }

    private static func drawOpenAIMark(in rect: NSRect) {
        guard let url = Bundle.main.url(forResource: "OpenAIMark", withExtension: "png"),
              let mark = NSImage(contentsOf: url) else { return }

        let side: CGFloat = 10.8
        let markRect = NSRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.sourceIn)
        context.setFillColor(NSColor.labelColor.cgColor)
        context.fill(markRect)
        context.restoreGState()
    }

    private static func drawStateIndicator(for phase: UsagePhase, in rect: NSRect) {
        let color: NSColor
        switch phase {
        case .failed: color = .systemRed
        case .needsConfiguration: color = .systemOrange
        default: color = .systemBlue
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 3.5, height: 3.5)).fill()
    }

    static func color(for progress: Double) -> NSColor {
        if progress >= 0.9 { return .systemRed }
        if progress >= 0.7 { return .systemOrange }
        return .systemGreen
    }
}
