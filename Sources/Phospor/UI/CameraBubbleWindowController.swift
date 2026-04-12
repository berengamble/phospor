import AVFoundation
import AppKit
import QuartzCore

/// A borderless, draggable, rounded floating window that hosts the live
/// webcam preview. Sits above other apps so the screen recorder picks it up
/// as part of the captured screen.
///
/// Behavior:
/// - Constrained inside the source's bounds with padding so the ring never
///   overlaps the source outline.
/// - When the user finishes dragging, the bubble animates to the nearest
///   corner of the allowed area.
/// - All programmatic repositioning (park, snap, bounds change) is animated
///   with a spring curve.
@MainActor
final class CameraBubbleWindowController: NSObject, NSWindowDelegate {
  private var window: NSPanel?
  private var hostView: BubbleHostView?
  private var previewLayer: AVCaptureVideoPreviewLayer?

  /// CG-space (top-left origin) rect that the bubble must stay inside.
  private var allowedBoundsCG: CGRect?

  /// Cocoa-space version of the allowed bounds, padded inward.
  private var paddedBoundsNS: NSRect?

  /// Default bubble diameter in points.
  var size: CGFloat = 180

  /// Padding between the bubble edge and the source outline.
  var padding: CGFloat = 16

  /// Border ring color.
  var borderColor: NSColor = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)

  /// Border ring thickness.
  var borderWidth: CGFloat = 2

  var isVisible: Bool { window?.isVisible ?? false }

  /// True while the user is actively dragging. Suppresses snap-to-corner
  /// during the drag.
  private var isDragging = false

  /// Debounce timer that fires snap-to-corner shortly after drag ends.
  private var snapTimer: Timer?

  // MARK: - Public API

  func show() {
    ensureWindow()
    guard let window else { return }

    let layer = previewLayer ?? CameraCaptureManager.shared.makePreviewLayer()
    previewLayer = layer

    if let host = hostView {
      host.installPreviewLayer(layer)
    }

    if window.frame == .zero || !window.isVisible {
      parkAtDefault(animated: false)
    }

    window.orderFrontRegardless()
    CameraCaptureManager.shared.start()
  }

  func hide() {
    CameraCaptureManager.shared.stop()
    window?.orderOut(nil)
  }

  /// Constrain the bubble inside this CG-space rect (the source's frame).
  /// Pass `nil` to remove the constraint. Animates to the nearest corner
  /// if the bubble is currently visible and outside the new bounds.
  func setAllowedBounds(_ cgRect: CGRect?) {
    allowedBoundsCG = cgRect
    recomputePaddedBounds()
    if window?.isVisible == true {
      snapToNearestCorner(animated: true)
    }
  }

  /// The NSWindow number for the recording filter.
  var windowNumber: Int? {
    window?.windowNumber
  }

  // MARK: - NSWindowDelegate

  nonisolated func windowDidMove(_ notification: Notification) {
    Task { @MainActor in
      // While dragging, just clamp — don't snap yet.
      self.isDragging = true
      self.clampToBounds()
      self.scheduleSnap()
    }
  }

  // MARK: - Snap & clamp

  /// Hard-clamp the bubble origin so it stays inside the padded bounds.
  /// No animation — used during live drag.
  private func clampToBounds() {
    guard let window, let allowed = paddedBoundsNS else { return }
    let frame = window.frame
    let clampedOrigin = clampedPoint(frame.origin, frameSize: frame.size, inside: allowed)
    if clampedOrigin != frame.origin {
      window.setFrameOrigin(clampedOrigin)
    }
  }

  /// Animate the bubble to the nearest corner of the padded bounds.
  private func snapToNearestCorner(animated: Bool) {
    guard let window, let allowed = paddedBoundsNS else { return }
    let s = window.frame.size
    let center = NSPoint(
      x: window.frame.midX,
      y: window.frame.midY
    )

    // Four corner origins (placing the bubble's origin, not its center).
    let corners: [NSPoint] = [
      NSPoint(x: allowed.minX, y: allowed.minY),  // bottom-left
      NSPoint(x: allowed.maxX - s.width, y: allowed.minY),  // bottom-right
      NSPoint(x: allowed.minX, y: allowed.maxY - s.height),  // top-left
      NSPoint(x: allowed.maxX - s.width, y: allowed.maxY - s.height),  // top-right
    ]

    // Pick the corner whose center is closest to the bubble's center.
    let nearest =
      corners.min(by: { a, b in
        let ca = NSPoint(x: a.x + s.width / 2, y: a.y + s.height / 2)
        let cb = NSPoint(x: b.x + s.width / 2, y: b.y + s.height / 2)
        return distance(center, ca) < distance(center, cb)
      }) ?? corners[1]

    if animated {
      animateToOrigin(nearest)
    } else {
      window.setFrameOrigin(nearest)
    }
    isDragging = false
  }

  /// Schedule a snap-to-corner after a brief pause once the user stops
  /// dragging. Debounced: rapid windowDidMove calls reset the timer so
  /// we only snap when the drag genuinely finishes.
  private func scheduleSnap() {
    snapTimer?.invalidate()
    snapTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.snapToNearestCorner(animated: true)
      }
    }
  }

  /// Place the bubble in the bottom-right corner on first show.
  private func parkAtDefault(animated: Bool) {
    guard let window else { return }
    let s = size

    if let allowed = paddedBoundsNS {
      let origin = NSPoint(
        x: allowed.maxX - s - padding,
        y: allowed.minY + padding
      )
      if animated {
        animateToOrigin(origin)
      } else {
        window.setFrame(NSRect(origin: origin, size: NSSize(width: s, height: s)), display: true)
      }
    } else if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      let origin = NSPoint(
        x: visible.maxX - s - 32,
        y: visible.minY + 32
      )
      window.setFrame(NSRect(origin: origin, size: NSSize(width: s, height: s)), display: true)
    }
  }

  // MARK: - Animation

  private func animateToOrigin(_ target: NSPoint) {
    guard let window else { return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.35
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.5, 1.0)
      ctx.allowsImplicitAnimation = true
      window.animator().setFrameOrigin(target)
    }
  }

  // MARK: - Geometry helpers

  private func recomputePaddedBounds() {
    guard let cgRect = allowedBoundsCG else {
      paddedBoundsNS = nil
      return
    }
    let padded = cgRect.insetBy(dx: padding, dy: padding)
    paddedBoundsNS = OutlineWindowController.cocoaRect(fromCG: padded)
  }

  private func clampedPoint(_ origin: NSPoint, frameSize: NSSize, inside allowed: NSRect) -> NSPoint
  {
    let maxX = max(allowed.minX, allowed.maxX - frameSize.width)
    let maxY = max(allowed.minY, allowed.maxY - frameSize.height)
    return NSPoint(
      x: max(allowed.minX, min(maxX, origin.x)),
      y: max(allowed.minY, min(maxY, origin.y))
    )
  }

  private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
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
    panel.sharingType = .readWrite
    panel.delegate = self

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

// MARK: - BubbleHostView

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

    let maskPath = CGPath(ellipseIn: bounds, transform: nil)
    maskLayer.path = maskPath
    maskLayer.frame = bounds
    host.mask = maskLayer
  }
}
