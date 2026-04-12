import AppKit
import QuartzCore

/// Borderless, click-through, transparent NSWindow that draws a cyan rounded
/// outline around a target rect. Used to highlight the source the user is
/// about to record. For window sources, polls the live window bounds at
/// ~30 Hz so the outline tracks the window as the user drags it around.
@MainActor
final class OutlineWindowController {
    private var window: NSWindow?
    private var shapeLayer: CAShapeLayer?
    private var trackedSource: CaptureSource?
    private var trackingTimer: Timer?
    private var lastFrame: CGRect = .zero

    /// Border thickness in points.
    var borderWidth: CGFloat = 4
    /// Corner radius for the outline.
    var cornerRadius: CGFloat = 10
    /// Inset (positive) shrinks the rect; negative grows it.
    var inset: CGFloat = 0
    /// Stroke color.
    var color: NSColor = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)

    func show(for source: CaptureSource) {
        trackedSource = source
        ensureWindow()
        applyCurrentFrame(force: true)
        window?.orderFrontRegardless()
        startTrackingIfNeeded()
    }

    func hide() {
        stopTracking()
        trackedSource = nil
        window?.orderOut(nil)
    }

    // MARK: - Tracking

    private func startTrackingIfNeeded() {
        stopTracking()
        // Only window sources move; displays are fixed.
        guard case .window = trackedSource else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyCurrentFrame(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func applyCurrentFrame(force: Bool) {
        guard let source = trackedSource else { return }
        let cgRect = currentFrame(for: source)
        // Skip redundant updates for steady-state polling.
        if !force && cgRect == lastFrame { return }
        lastFrame = cgRect
        guard let nsRect = Self.cocoaRect(fromCG: cgRect) else { return }
        guard let window, let shapeLayer else { return }

        window.setFrame(nsRect, display: true)

        let path = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: nsRect.size)
                .insetBy(dx: inset + borderWidth / 2, dy: inset + borderWidth / 2),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        shapeLayer.path = path.cgPath
        shapeLayer.lineWidth = borderWidth
        shapeLayer.strokeColor = color.cgColor
        shapeLayer.fillColor = NSColor.clear.cgColor
    }

    /// Resolve the current on-screen rect for a source. For windows we ask
    /// CoreGraphics for live bounds; for displays the static frame is fine.
    private func currentFrame(for source: CaptureSource) -> CGRect {
        switch source {
        case .display(let d):
            return d.frame
        case .window(let w):
            if let infos = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], w.windowID
            ) as? [[String: Any]],
               let info = infos.first,
               let bounds = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                return rect
            }
            return w.frame
        }
    }

    // MARK: - Plumbing

    private func ensureWindow() {
        if window != nil { return }

        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Try to make sure ScreenCaptureKit can exclude us by name later.
        w.sharingType = .none
        w.title = "Phospor Outline"

        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()

        let shape = CAShapeLayer()
        shape.fillColor = NSColor.clear.cgColor
        shape.strokeColor = color.cgColor
        shape.lineWidth = borderWidth
        // Subtle outer glow to match the mainframe aesthetic.
        shape.shadowColor = color.cgColor
        shape.shadowOpacity = 0.7
        shape.shadowRadius = 6
        shape.shadowOffset = .zero

        view.layer?.addSublayer(shape)
        w.contentView = view

        self.window = w
        self.shapeLayer = shape
    }

    /// Convert a CoreGraphics global rect (origin top-left of primary display)
    /// to a Cocoa global rect (origin bottom-left of primary display).
    static func cocoaRect(fromCG cgRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            return nil
        }
        let primaryHeight = primary.frame.height
        return NSRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}

// MARK: - NSBezierPath → CGPath bridge

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }
        return path
    }
}
