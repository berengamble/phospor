import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// Wraps ScreenCaptureKit for source enumeration and recording. Public API
/// is callable from any actor; the SCStream output callback runs on a
/// dedicated serial queue and feeds the `RecordingWriter` directly.
final class ScreenCaptureManager: NSObject, @unchecked Sendable {
    static let shared = ScreenCaptureManager()
    private override init() { super.init() }

    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: RecordingWriter?
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
    /// own UI (control panel, outline overlay, …) from the capture.
    func startRecording(
        source: CaptureSource,
        excludedWindowNumbers: [Int],
        outputURL: URL
    ) async throws {
        // Re-fetch shareable content so we can map our NSWindow numbers to
        // SCWindows for exclusion.
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

        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: excludedSCWindows)
            // SCDisplay.width/height are in points; multiply by backing scale
            // for native pixel resolution.
            pointPixelScale = Self.backingScale(for: display)
            width = Int(CGFloat(display.width) * pointPixelScale)
            height = Int(CGFloat(display.height) * pointPixelScale)

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointPixelScale = NSScreen.main?.backingScaleFactor ?? 2
            width = Int(window.frame.width * pointPixelScale)
            height = Int(window.frame.height * pointPixelScale)
        }

        // H.264 needs even dimensions.
        width  = (width  / 2) * 2
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 fps cap
        config.queueDepth = 6
        config.showsCursor = true
        config.scalesToFit = true

        let writer = try RecordingWriter(outputURL: outputURL, width: width, height: height)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await newStream.startCapture()

        commit(writer: writer, stream: newStream)
    }

    /// Stop the current recording and return the finalized output URL.
    func stopRecording() async throws -> URL? {
        let (s, w) = takeStreamAndWriter()
        guard let s, let w else { return nil }
        try await s.stopCapture()
        return await w.finish()
    }

    // MARK: - Locked accessors

    private func commit(writer: RecordingWriter, stream: SCStream) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
        self.stream = stream
    }

    private func takeStreamAndWriter() -> (SCStream?, RecordingWriter?) {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        let w = writer
        stream = nil
        writer = nil
        return (s, w)
    }

    private func currentWriter() -> RecordingWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }

    // MARK: - Helpers

    /// Resolve the backing scale factor (pixels per point) for a display.
    /// Falls back to the main screen if a direct mapping isn't found.
    private static func backingScale(for display: SCDisplay) -> CGFloat {
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               id == display.displayID {
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
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let statusRaw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else { return }

        currentWriter()?.append(sampleBuffer)
    }
}
