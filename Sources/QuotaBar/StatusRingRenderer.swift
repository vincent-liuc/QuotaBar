import AppKit

@MainActor
enum StatusRingRenderer {
    static func image(progress: Double?, phase: UsagePhase, wavePhase: Double = 0) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            if let progress {
                drawCat(progress: progress, wavePhase: wavePhase, in: rect.insetBy(dx: 1, dy: 1))
            } else {
                drawCat(progress: 0, wavePhase: wavePhase, in: rect.insetBy(dx: 1, dy: 1))
                drawStateIndicator(for: phase, in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawCat(progress: Double, wavePhase: Double, in rect: NSRect) {
        let bounded = min(max(progress, 0), 1)
        drawCatShape(in: rect, color: NSColor(calibratedWhite: 0.08, alpha: 1))
        if bounded > 0, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            let fillTop = rect.minY + rect.height * bounded
            let amplitude = min(rect.height * 0.045, 0.8)
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: rect.minX, y: rect.minY))
            wave.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            wave.line(to: NSPoint(x: rect.maxX, y: fillTop))
            let segments = 16
            for index in stride(from: segments, through: 0, by: -1) {
                let fraction = CGFloat(index) / CGFloat(segments)
                let angle = Double(fraction) * .pi * 2 + wavePhase
                wave.line(to: NSPoint(
                    x: rect.minX + rect.width * fraction,
                    y: fillTop + CGFloat(sin(angle)) * amplitude
                ))
            }
            wave.close()
            wave.addClip()
            drawCatShape(in: rect, color: .systemGreen)
            context.restoreGState()
        }
        drawFace(in: rect)
    }

    private static func drawCatShape(in rect: NSRect, color: NSColor) {
        let point: (CGFloat, CGFloat) -> NSPoint = { x, y in
            NSPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }

        let head = NSBezierPath()
        head.move(to: point(11, 91))
        head.line(to: point(31, 75))
        head.curve(to: point(69, 75), controlPoint1: point(42, 81), controlPoint2: point(58, 81))
        head.line(to: point(89, 91))
        head.line(to: point(84, 61))
        head.curve(to: point(76, 24), controlPoint1: point(91, 48), controlPoint2: point(87, 30))
        head.curve(to: point(24, 24), controlPoint1: point(63, 3), controlPoint2: point(37, 3))
        head.curve(to: point(16, 61), controlPoint1: point(13, 30), controlPoint2: point(9, 48))
        head.close()

        color.setFill()
        head.fill()
    }

    private static func drawFace(in rect: NSRect) {
        let point: (CGFloat, CGFloat) -> NSPoint = { x, y in
            NSPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        NSColor.clear.setFill()
        NSBezierPath(ovalIn: NSRect(x: point(31, 53).x, y: point(31, 53).y, width: rect.width * 0.09, height: rect.height * 0.12)).fill()
        NSBezierPath(ovalIn: NSRect(x: point(60, 53).x, y: point(60, 53).y, width: rect.width * 0.09, height: rect.height * 0.12)).fill()
        let nose = NSBezierPath()
        nose.move(to: point(45, 43))
        nose.line(to: point(55, 43))
        nose.line(to: point(50, 37))
        nose.close()
        nose.fill()
        let whiskers = NSBezierPath()
        whiskers.move(to: point(31, 41))
        whiskers.line(to: point(12, 45))
        whiskers.move(to: point(31, 34))
        whiskers.line(to: point(13, 31))
        whiskers.move(to: point(69, 41))
        whiskers.line(to: point(88, 45))
        whiskers.move(to: point(69, 34))
        whiskers.line(to: point(87, 31))
        whiskers.lineWidth = max(rect.width * 0.045, 0.8)
        whiskers.lineCapStyle = .round
        whiskers.stroke()
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
