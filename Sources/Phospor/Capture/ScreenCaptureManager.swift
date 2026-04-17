import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Wraps ScreenCaptureKit for source enumeration and recording. Public API
/// is callable from any actor; the SCStream output callback runs on a
/// dedicated serial queue and feeds the `RecordingWriter` directly.
final class ScreenCaptureManager: NSObject, @unchecked Sendable {
  static let shared = ScreenCaptureManager()
  private override init() { super.init() }

  private let lock = NSLock()
  private var stream: SCStream?
  private var writer: RecordingWriter?
  private var markerStore: MarkerStore?
  private var audioLevelMonitor: AudioLevelMonitor?
  private let outputQueue = DispatchQueue(label: "phospor.scstream.output")

  // MARK: - Permissions

  /// Whether the process currently has Screen Recording permission. Cheap
  /// preflight call — does not show a UI prompt.
  func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Triggers the system prompt the very first time, otherwise returns the
  /// cached state. Does NOT re-prompt if previously denied — TCC requires the
  /// user to flip the toggle in System Settings in that case.
  @discardableResult
  func requestScreenRecordingPermission() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  // MARK: - Source enumeration

  func loadSources() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true,
      onScreenWindowsOnly: true
    )

    let ownPID = ProcessInfo.processInfo.processIdentifier
    let minSide: CGFloat = 80

    let windows = content.windows
      .filter { w in
        guard w.owningApplication?.processID != ownPID else { return false }
        guard w.frame.width >= minSide, w.frame.height >= minSide else { return false }
        guard w.windowLayer == 0 else { return false }
        return true
      }
      .sorted { a, b in
        let aa = a.owningApplication?.applicationName ?? ""
        let bb = b.owningApplication?.applicationName ?? ""
        if aa != bb { return aa.localizedCaseInsensitiveCompare(bb) == .orderedAscending }
        return (a.title ?? "").localizedCaseInsensitiveCompare(b.title ?? "") == .orderedAscending
      }

    let displays = content.displays.sorted { $0.displayID < $1.displayID }
    return (displays, windows)
  }

  // MARK: - Recording

  /// Start a new recording. `excludedWindowNumbers` lets the caller hide its
  /// own UI (control panel, outline overlay, …) from the capture. Pass
  /// `recordMicrophone: true` to mux mic audio into the output mp4.
  func startRecording(
    source: CaptureSource,
    excludedWindowNumbers: [Int],
    cameraBubbleWindowNumber: Int?,
    recordMicrophone: Bool,
    markerStore: MarkerStore,
    audioLevelMonitor: AudioLevelMonitor?,
    outputURL: URL
  ) async throws {
    // Re-fetch shareable content so we can map our NSWindow numbers to
    // SCWindows for exclusion / inclusion.
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    let excludedSet = Set(excludedWindowNumbers.map { CGWindowID($0) })
    let excludedSCWindows = content.windows.filter { excludedSet.contains($0.windowID) }

    let filter: SCContentFilter
    var width: Int
    var height: Int
    var pointPixelScale: CGFloat = 1
    var windowSourceRect: CGRect? = nil

    switch source {
    case .display(let display):
      filter = SCContentFilter(display: display, excludingWindows: excludedSCWindows)
      pointPixelScale = Self.backingScale(for: display)
      width = Int(CGFloat(display.width) * pointPixelScale)
      height = Int(CGFloat(display.height) * pointPixelScale)

    case .window(let window):
      // Use display + including-windows filter so the camera bubble is
      // rendered alongside the target window. sourceRect crops the
      // captured area to the window's bounds.
      let display = Self.displayContaining(window, in: content.displays)
      pointPixelScale = Self.backingScale(for: display)

      var included: [SCWindow] = [window]
      if let bubbleNum = cameraBubbleWindowNumber {
        let bubbleID = CGWindowID(bubbleNum)
        if let bubbleSCW = content.windows.first(where: { $0.windowID == bubbleID }) {
          included.append(bubbleSCW)
        }
      }

      filter = SCContentFilter(display: display, including: included)

      // sourceRect in display-local points (top-left origin).
      let srcRect = CGRect(
        x: window.frame.minX - display.frame.minX,
        y: window.frame.minY - display.frame.minY,
        width: window.frame.width,
        height: window.frame.height
      )
      windowSourceRect = srcRect

      width = Int(window.frame.width * pointPixelScale)
      height = Int(window.frame.height * pointPixelScale)
    }

    // H.264 needs even dimensions.
    width = (width / 2) * 2
    height = (height / 2) * 2
    guard width > 0, height > 0 else {
      throw NSError(
        domain: "phospor.capture",
        code: -10,
        userInfo: [NSLocalizedDescriptionKey: "source has zero dimensions"]
      )
    }

    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60 fps cap
    config.queueDepth = 6
    config.showsCursor = true
    config.scalesToFit = true
    if let rect = windowSourceRect {
      config.sourceRect = rect
    }

    let writer = try RecordingWriter(
      outputURL: outputURL,
      width: width,
      height: height,
      includeAudio: recordMicrophone
    )

    let newStream = SCStream(filter: filter, configuration: config, delegate: self)
    try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
    try await newStream.startCapture()

    self.audioLevelMonitor = audioLevelMonitor
    commit(writer: writer, stream: newStream, markers: markerStore)

    // Wire the microphone — kicks off after the screen stream so the
    // first video frame establishes the writer session before audio
    // arrives. Audio samples that beat the first video frame are
    // dropped by the writer.
    if recordMicrophone {
      let monitor = audioLevelMonitor
      AudioCaptureManager.shared.start { [weak self] sampleBuffer in
        self?.currentWriter()?.appendAudio(sampleBuffer)
        monitor?.process(sampleBuffer)
      }
    }
  }

  /// Stop the current recording and return the finalized output URL.
  func stopRecording() async throws -> URL? {
    AudioCaptureManager.shared.stop()
    let (s, w, m) = takeStreamAndWriter()
    guard let s, let w else { return nil }
    try await s.stopCapture()
    return await w.finish(markerStore: m)
  }

  // MARK: - Locked accessors

  private func commit(writer: RecordingWriter, stream: SCStream, markers: MarkerStore) {
    lock.lock()
    defer { lock.unlock() }
    self.writer = writer
    self.stream = stream
    self.markerStore = markers
  }

  private func takeStreamAndWriter() -> (SCStream?, RecordingWriter?, MarkerStore?) {
    lock.lock()
    defer { lock.unlock() }
    let s = stream
    let w = writer
    let m = markerStore
    stream = nil
    writer = nil
    markerStore = nil
    return (s, w, m)
  }

  private func currentWriter() -> RecordingWriter? {
    lock.lock()
    defer { lock.unlock() }
    return writer
  }

  // MARK: - Helpers

  /// Find the display whose frame overlaps most with the given window.
  private static func displayContaining(_ window: SCWindow, in displays: [SCDisplay]) -> SCDisplay {
    displays.max(by: { a, b in
      let areaA =
        a.frame.intersection(window.frame).width * a.frame.intersection(window.frame).height
      let areaB =
        b.frame.intersection(window.frame).width * b.frame.intersection(window.frame).height
      return areaA < areaB
    }) ?? displays[0]
  }

  /// Resolve the backing scale factor (pixels per point) for a display.
  /// Falls back to the main screen if a direct mapping isn't found.
  private static func backingScale(for display: SCDisplay) -> CGFloat {
    for screen in NSScreen.screens {
      if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? CGDirectDisplayID,
        id == display.displayID
      {
        return screen.backingScaleFactor
      }
    }
    return NSScreen.main?.backingScaleFactor ?? 2
  }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureManager: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    NSLog("[phospor] SCStream stopped with error: \(error.localizedDescription)")
  }
}

// MARK: - SCStreamOutput

extension ScreenCaptureManager: SCStreamOutput {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    guard sampleBuffer.isValid else { return }

    // Only forward "complete" frames (skip idle/blank/suspended).
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first,
      let statusRaw = info[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRaw),
      status == .complete
    else { return }

    currentWriter()?.appendVideo(sampleBuffer)
  }
}
