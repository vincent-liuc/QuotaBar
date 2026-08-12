import AppKit

@MainActor
enum StatusRingRenderer {
    static func image(progress: Double?, phase: UsagePhase) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            if let progress {
                drawCat(progress: progress, in: rect.insetBy(dx: 1, dy: 1))
            } else {
                drawCat(progress: 0, in: rect.insetBy(dx: 1, dy: 1))
                drawStateIndicator(for: phase, in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawCat(progress: Double, in rect: NSRect) {
        let bounded = min(max(progress, 0), 1)
        drawCatShape(in: rect, color: NSColor(calibratedWhite: 0.08, alpha: 1))
        guard bounded > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * bounded))
        drawCatShape(in: rect, color: .systemGreen)
        context.restoreGState()
    }

    private static func drawCatShape(in rect: NSRect, color: NSColor) {
        let point: (CGFloat, CGFloat) -> NSPoint = { x, y in
            NSPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }

        let head = NSBezierPath()
        head.move(to: point(18, 88))
        head.line(to: point(31, 78))
        head.curve(to: point(50, 83), controlPoint1: point(37, 82), controlPoint2: point(43, 83))
        head.curve(to: point(69, 78), controlPoint1: point(57, 83), controlPoint2: point(63, 82))
        head.line(to: point(82, 88))
        head.line(to: point(77, 66))
        head.curve(to: point(82, 51), controlPoint1: point(81, 62), controlPoint2: point(83, 57))
        head.curve(to: point(68, 35), controlPoint1: point(81, 42), controlPoint2: point(76, 37))
        head.curve(to: point(32, 35), controlPoint1: point(58, 31), controlPoint2: point(42, 31))
        head.curve(to: point(18, 51), controlPoint1: point(24, 37), controlPoint2: point(19, 42))
        head.curve(to: point(23, 66), controlPoint1: point(17, 57), controlPoint2: point(19, 62))
        head.close()

        let body = NSBezierPath()
        body.move(to: point(36, 39))
        body.curve(to: point(24, 8), controlPoint1: point(25, 31), controlPoint2: point(22, 18))
        body.line(to: point(46, 8))
        body.line(to: point(49, 24))
        body.curve(to: point(55, 24), controlPoint1: point(51, 23), controlPoint2: point(53, 23))
        body.line(to: point(58, 8))
        body.line(to: point(76, 8))
        body.curve(to: point(64, 39), controlPoint1: point(78, 20), controlPoint2: point(74, 32))
        body.close()

        color.setFill()
        head.fill()
        body.fill()

        let tail = NSBezierPath()
        tail.move(to: point(64, 27))
        tail.curve(to: point(91, 13), controlPoint1: point(72, 19), controlPoint2: point(84, 30))
        tail.lineWidth = max(rect.width * 0.12, 1.5)
        tail.lineCapStyle = .round
        color.setStroke()
        tail.stroke()
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
