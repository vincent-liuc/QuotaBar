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
        head.move(to: point(7, 94))
        head.line(to: point(31, 79))
        head.curve(to: point(69, 79), controlPoint1: point(42, 84), controlPoint2: point(58, 84))
        head.line(to: point(93, 94))
        head.line(to: point(87, 53))
        head.curve(to: point(84, 31), controlPoint1: point(91, 45), controlPoint2: point(89, 36))
        head.curve(to: point(72, 20), controlPoint1: point(82, 25), controlPoint2: point(78, 22))
        head.curve(to: point(62, 11), controlPoint1: point(69, 14), controlPoint2: point(65, 11))
        head.curve(to: point(50, 8), controlPoint1: point(58, 8), controlPoint2: point(54, 7))
        head.curve(to: point(38, 11), controlPoint1: point(46, 7), controlPoint2: point(42, 8))
        head.curve(to: point(28, 20), controlPoint1: point(35, 11), controlPoint2: point(31, 14))
        head.curve(to: point(16, 31), controlPoint1: point(22, 22), controlPoint2: point(18, 25))
        head.curve(to: point(13, 53), controlPoint1: point(11, 36), controlPoint2: point(9, 45))
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
        let leftEye = NSBezierPath()
        leftEye.move(to: point(27, 57))
        leftEye.curve(to: point(43, 55), controlPoint1: point(32, 62), controlPoint2: point(39, 61))
        leftEye.curve(to: point(27, 57), controlPoint1: point(39, 51), controlPoint2: point(32, 51))
        leftEye.fill()
        let rightEye = NSBezierPath()
        rightEye.move(to: point(57, 55))
        rightEye.curve(to: point(73, 57), controlPoint1: point(61, 61), controlPoint2: point(68, 62))
        rightEye.curve(to: point(57, 55), controlPoint1: point(68, 51), controlPoint2: point(61, 51))
        rightEye.fill()
        let nose = NSBezierPath()
        nose.move(to: point(44, 43))
        nose.line(to: point(56, 43))
        nose.line(to: point(50, 36))
        nose.close()
        nose.fill()
        let mouth = NSBezierPath()
        mouth.move(to: point(50, 36))
        mouth.curve(to: point(43, 30), controlPoint1: point(49, 32), controlPoint2: point(46, 30))
        mouth.move(to: point(50, 36))
        mouth.curve(to: point(57, 30), controlPoint1: point(51, 32), controlPoint2: point(54, 30))
        mouth.lineWidth = max(rect.width * 0.035, 0.7)
        mouth.lineCapStyle = .round
        mouth.stroke()
        let whiskers = NSBezierPath()
        whiskers.move(to: point(34, 42))
        whiskers.line(to: point(17, 45))
        whiskers.move(to: point(34, 35))
        whiskers.line(to: point(18, 32))
        whiskers.move(to: point(66, 42))
        whiskers.line(to: point(83, 45))
        whiskers.move(to: point(66, 35))
        whiskers.line(to: point(82, 32))
        whiskers.lineWidth = max(rect.width * 0.032, 0.65)
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
