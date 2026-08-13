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
        let catRect = fittedCatRect(in: rect)
        catTemplate.draw(
            in: catRect,
            from: NSRect(origin: .zero, size: catTemplate.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        if bounded > 0, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            let fillTop = catRect.minY + catRect.height * bounded
            let amplitude = min(catRect.height * 0.045, 0.8)
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: catRect.minX, y: catRect.minY))
            wave.line(to: NSPoint(x: catRect.maxX, y: catRect.minY))
            wave.line(to: NSPoint(x: catRect.maxX, y: fillTop))
            let segments = 16
            for index in stride(from: segments, through: 0, by: -1) {
                let fraction = CGFloat(index) / CGFloat(segments)
                let angle = Double(fraction) * .pi * 2 + wavePhase
                wave.line(to: NSPoint(
                    x: catRect.minX + catRect.width * fraction,
                    y: fillTop + CGFloat(sin(angle)) * amplitude
                ))
            }
            wave.close()
            wave.addClip()
            context.setBlendMode(.sourceAtop)
            NSColor.systemGreen.setFill()
            NSBezierPath(rect: catRect).fill()
            context.restoreGState()
        }
    }

    private static func fittedCatRect(in rect: NSRect) -> NSRect {
        let aspectRatio = catTemplate.size.width / catTemplate.size.height
        let width = min(rect.width, rect.height * aspectRatio)
        return NSRect(
            x: rect.midX - width / 2,
            y: rect.minY,
            width: width,
            height: rect.height
        )
    }

    private static let catTemplate: NSImage = {
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" width="900" height="935" viewBox="220 160 900 935">
          <path fill="#141414" fill-rule="evenodd" clip-rule="evenodd" d="M 307 174 L 287 211 L 273 297 L 277 391 L 297 454 L 248 536 L 231 630 L 244 687 L 280 738 L 330 774 L 408 804 L 372 862 L 359 904 L 323 950 L 320 991 L 336 1027 L 383 1057 L 417 1061 L 468 1052 L 491 1074 L 524 1084 L 574 1080 L 621 1053 L 665 1080 L 715 1084 L 754 1071 L 776 1050 L 850 1060 L 902 1038 L 972 1028 L 1022 1007 L 1062 978 L 1097 932 L 1111 882 L 1103 819 L 1070 772 L 1036 755 L 995 753 L 956 767 L 927 795 L 916 839 L 931 863 L 966 862 L 984 831 L 997 824 L 1014 829 L 1026 853 L 1024 881 L 1004 919 L 974 947 L 932 969 L 913 927 L 888 904 L 874 859 L 838 804 L 910 774 L 958 741 L 993 699 L 1013 640 L 1012 589 L 999 541 L 946 453 L 970 383 L 973 291 L 970 271 L 940 268 L 925 248 L 929 226 L 952 211 L 938 178 L 911 170 L 853 197 L 790 244 L 725 310 L 603 298 L 518 311 L 462 252 L 393 199 L 334 171 Z M 593 652 L 602 649 L 609 649 L 610 648 L 637 648 L 638 649 L 648 650 L 652 652 L 657 657 L 659 663 L 658 669 L 653 678 L 641 692 L 634 698 L 628 701 L 620 702 L 609 696 L 596 683 L 589 673 L 586 666 L 586 662 L 588 657 Z M 440 497 L 466 496 L 479 499 L 494 506 L 509 517 L 523 532 L 531 544 L 538 558 L 545 583 L 546 604 L 545 605 L 544 618 L 537 638 L 530 649 L 515 665 L 508 670 L 492 678 L 475 683 L 468 683 L 467 684 L 437 683 L 421 679 L 404 671 L 397 666 L 383 652 L 376 642 L 370 629 L 366 613 L 365 591 L 366 590 L 366 583 L 368 573 L 375 553 L 381 542 L 392 527 L 405 514 L 425 502 Z M 465 535 L 454 539 L 443 551 L 435 572 L 433 598 L 434 599 L 435 615 L 438 625 L 443 635 L 454 647 L 461 650 L 471 650 L 480 646 L 487 639 L 494 626 L 499 604 L 499 581 L 496 566 L 489 550 L 477 538 Z M 789 495 L 806 496 L 821 500 L 836 508 L 847 517 L 860 532 L 873 556 L 878 573 L 879 584 L 880 585 L 880 609 L 878 619 L 874 631 L 864 649 L 849 665 L 837 673 L 818 681 L 802 684 L 779 684 L 778 683 L 767 682 L 747 675 L 737 669 L 719 652 L 711 640 L 705 625 L 702 610 L 702 585 L 706 567 L 714 548 L 726 530 L 741 515 L 754 506 L 772 498 L 781 496 L 788 496 Z M 775 535 L 768 537 L 763 540 L 757 546 L 751 556 L 746 570 L 746 575 L 744 581 L 744 606 L 749 626 L 756 639 L 762 645 L 769 649 L 782 650 L 791 645 L 799 637 L 804 627 L 809 608 L 810 584 L 807 568 L 799 549 L 787 538 Z"/>
        </svg>
        """#
        return NSImage(data: Data(svg.utf8)) ?? NSImage()
    }()

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
