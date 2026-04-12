import AppKit
import AVFoundation
import QuartzCore

/// A borderless, draggable, rounded floating window that hosts the live
/// webcam preview. Sits above other apps so the screen recorder picks it up
/// as part of the captured screen.
@MainActor
final class CameraBubbleWindowController {
    private var window: NSPanel?
    private var hostView: BubbleHostView?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Default bubble diameter in points (square; rounded into a circle by
    /// the corner radius).
    var size: CGFloat = 180

    /// Border ring color.
    var borderColor: NSColor = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)

    /// Border ring thickness.
    var borderWidth: CGFloat = 2

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        ensureWindow()
        guard let window else { return }

        let layer = previewLayer ?? CameraCaptureManager.shared.makePreviewLayer()
        previewLayer = layer

        if let host = hostView {
            host.installPreviewLayer(layer)
        }

        // Park the bubble in the bottom-right of the active screen on first
        // show; subsequent shows preserve the user's last position.
        if window.frame == .zero || !window.isVisible, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let s = size
            let origin = NSPoint(
                x: visible.maxX - s - 32,
                y: visible.minY + 32
            )
            window.setFrame(NSRect(origin: origin, size: NSSize(width: s, height: s)), display: true)
        }

        window.orderFrontRegardless()
        CameraCaptureManager.shared.start()
    }

    func hide() {
        CameraCaptureManager.shared.stop()
        window?.orderOut(nil)
    }

    /// The window number, so the recording filter can include it in the
    /// captured video (and never exclude it).
    var windowNumber: Int? {
        window?.windowNumber
    }

    // MARK: - Plumbing

    private func ensureWindow() {
        if window != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.acceptsMouseMovedEvents = false
        // Important: keep sharingType default so ScreenCaptureKit captures us.
        panel.sharingType = .readWrite

        let host = BubbleHostView(
            frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
            borderColor: borderColor,
            borderWidth: borderWidth
        )
        panel.contentView = host

        self.window = panel
        self.hostView = host
    }
}

/// View that hosts the camera preview layer with a circular mask and a
/// cyan border ring. Click+drag anywhere moves the window because we set
/// `isMovableByWindowBackground` on the parent panel.
private final class BubbleHostView: NSView {
    private let borderColor: NSColor
    private let borderWidth: CGFloat
    private let ringLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private var hostedPreview: AVCaptureVideoPreviewLayer?

    init(frame frameRect: NSRect, borderColor: NSColor, borderWidth: CGFloat) {
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        rebuildLayers()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        rebuildLayers()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    fileprivate func installPreviewLayer(_ preview: AVCaptureVideoPreviewLayer) {
        if hostedPreview === preview { return }
        hostedPreview?.removeFromSuperlayer()

        guard let host = layer else { return }
        preview.frame = host.bounds
        preview.cornerRadius = host.bounds.width / 2
        preview.masksToBounds = true
        host.insertSublayer(preview, at: 0)
        hostedPreview = preview
        rebuildLayers()
    }

    private func rebuildLayers() {
        guard let host = layer else { return }
        let bounds = host.bounds

        hostedPreview?.frame = bounds
        hostedPreview?.cornerRadius = bounds.width / 2
        hostedPreview?.masksToBounds = true

        // Cyan border ring on the inside edge.
        let ringPath = CGPath(
            ellipseIn: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
            transform: nil
        )
        ringLayer.path = ringPath
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = borderColor.cgColor
        ringLayer.lineWidth = borderWidth
        ringLayer.frame = bounds
        ringLayer.shadowColor = borderColor.cgColor
        ringLayer.shadowOpacity = 0.7
        ringLayer.shadowRadius = 8
        ringLayer.shadowOffset = .zero
        if ringLayer.superlayer == nil {
            host.addSublayer(ringLayer)
        }

        // Mask the host layer itself so the corners are clipped — belt and
        // braces alongside the preview layer's own corner radius.
        let maskPath = CGPath(ellipseIn: bounds, transform: nil)
        maskLayer.path = maskPath
        maskLayer.frame = bounds
        host.mask = maskLayer
    }
}
