import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controlPanel: NSPanel?
  private var sourcePickerPanel: NSPanel?
  private let outline = OutlineWindowController()
  private let cameraBubble = CameraBubbleWindowController()
  private let state = RecordingState()
  private var currentMarkerStore: MarkerStore?
  private var markerServer: MarkerServer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    showControlPanel()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  // MARK: - Control panel window

  private func showControlPanel() {
    if let existing = controlPanel {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let view = ControlPanelView(
      state: state,
      onClose: { NSApp.terminate(nil) },
      onPickSource: { [weak self] in self?.handlePickSource() },
      onToggleRecord: { [weak self] in self?.handleToggleRecord() },
      onToggleCamera: { [weak self] in self?.handleToggleCamera() },
      onToggleMicrophone: { [weak self] in self?.handleToggleMicrophone() }
    )

    let hosting = NSHostingView(rootView: view)
    hosting.translatesAutoresizingMaskIntoConstraints = false

    // Borderless floating panel — no titlebar, no traffic lights.
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
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
    panel.contentView = hosting

    // Center on the active screen with a slight rightward bias, like Loom.
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      let size =
        hosting.fittingSize == .zero ? NSSize(width: 320, height: 480) : hosting.fittingSize
      let origin = NSPoint(
        x: frame.maxX - size.width - 40,
        y: frame.midY - size.height / 2
      )
      panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    controlPanel = panel
  }

  func applicationWillTerminate(_ notification: Notification) {
    outline.hide()
    cameraBubble.hide()
  }

  // MARK: - Camera

  private func handleToggleCamera() {
    if state.cameraEnabled {
      // Turn off
      cameraBubble.hide()
      state.cameraEnabled = false
      state.cameraDeniedHint = nil
      return
    }

    // Turn on — request permission first.
    Task {
      let granted = await CameraCaptureManager.shared.requestPermission()
      await MainActor.run {
        if granted {
          self.cameraBubble.show()
          self.state.cameraEnabled = true
          self.state.cameraDeniedHint = nil
        } else {
          self.state.cameraEnabled = false
          self.state.cameraDeniedHint = "PERMISSION DENIED — OPEN SETTINGS"
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
  }

  private func handleToggleMicrophone() {
    if state.microphoneEnabled {
      state.microphoneEnabled = false
      state.microphoneDeniedHint = nil
      return
    }

    Task {
      let granted = await AudioCaptureManager.shared.requestPermission()
      await MainActor.run {
        if granted {
          self.state.microphoneEnabled = true
          self.state.microphoneDeniedHint = nil
        } else {
          self.state.microphoneEnabled = false
          self.state.microphoneDeniedHint = "PERMISSION DENIED — OPEN SETTINGS"
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
  }

  // MARK: - Source picker (child window, slides out from the left edge)

  private func handlePickSource() {
    if sourcePickerPanel != nil {
      closeSourcePicker()
      return
    }
    guard let anchor = controlPanel else { return }

    // Pre-fetch sources so the panel appears fully populated.
    Task {
      let sources: (displays: [SCDisplay], windows: [SCWindow])?
      do {
        sources = try await ScreenCaptureManager.shared.loadSources()
      } catch {
        sources = nil
      }

      await MainActor.run {
        self.showSourcePicker(anchor: anchor, prefetched: sources)
      }
    }
  }

  private func showSourcePicker(
    anchor: NSPanel,
    prefetched: (displays: [SCDisplay], windows: [SCWindow])?
  ) {
    let view = SourcePickerView(
      prefetchedSources: prefetched,
      onSelect: { [weak self] source in
        guard let self else { return }
        self.state.source = source
        self.outline.show(for: source)
        self.cameraBubble.setAllowedBounds(source.frame)
        self.closeSourcePicker()
      },
      onClose: { [weak self] in self?.closeSourcePicker() }
    )

    let hosting = NSHostingView(rootView: view)
    let pickerSize = hosting.fittingSize == .zero
      ? NSSize(width: 400, height: anchor.frame.height)
      : NSSize(width: hosting.fittingSize.width, height: max(hosting.fittingSize.height, anchor.frame.height))

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: pickerSize),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = false
    panel.hasShadow = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.contentView = hosting

    // Position flush-left of the control panel.
    let finalFrame = NSRect(
      x: anchor.frame.minX - pickerSize.width,
      y: anchor.frame.maxY - pickerSize.height,
      width: pickerSize.width,
      height: pickerSize.height
    )
    panel.setFrame(finalFrame, display: true)
    panel.orderFront(nil)

    anchor.addChildWindow(panel, ordered: .below)
    sourcePickerPanel = panel
  }

  private func closeSourcePicker() {
    sourcePickerPanel?.close()
    sourcePickerPanel = nil
  }

  private func handleToggleRecord() {
    switch state.phase {
    case .idle, .armed:
      startRecording()
    case .recording:
      stopRecording()
    case .stopping:
      break
    }
  }

  private func startRecording() {
    guard let source = state.source else {
      NSLog("[phospor] start requested with no source selected")
      return
    }

    let outputURL = Self.makeOutputURL()
    let excluded = excludedWindowNumbers()
    let bubbleNum = cameraBubble.isVisible ? cameraBubble.windowNumber : nil
    let withMic = state.microphoneEnabled

    let markers = MarkerStore()
    markers.videoURL = outputURL
    markers.onMarkerAdded = { [weak self] marker in
      self?.state.markerCount += 1
      self?.state.lastMarkerLabel = marker.chapterTitle
    }
    currentMarkerStore = markers

    // Start the marker HTTP endpoint so hooks can POST events.
    let server = MarkerServer(markerStore: markers)
    try? server.start()
    markerServer = server

    // Audio level monitor for speech markers.
    let audioMonitor = withMic
      ? AudioLevelMonitor(markerStore: markers, thresholdDB: state.audioThresholdDB)
      : nil
    audioMonitor?.onLevelUpdate = { [weak self] db in
      self?.state.audioLevelDB = db
    }

    Task {
      do {
        try await ScreenCaptureManager.shared.startRecording(
          source: source,
          excludedWindowNumbers: excluded,
          cameraBubbleWindowNumber: bubbleNum,
          recordMicrophone: withMic,
          markerStore: markers,
          audioLevelMonitor: audioMonitor,
          outputURL: outputURL
        )
        await MainActor.run { self.state.phase = .recording }
        NSLog("[phospor] recording → \(outputURL.path)")
      } catch {
        NSLog("[phospor] failed to start recording: \(error.localizedDescription)")
        await MainActor.run { self.state.phase = .armed }
      }
    }
  }

  private func stopRecording() {
    state.phase = .stopping
    markerServer?.stop()
    markerServer = nil
    currentMarkerStore = nil
    Task {
      do {
        let url = try await ScreenCaptureManager.shared.stopRecording()
        await MainActor.run {
          self.state.phase = self.state.source == nil ? .idle : .armed
          self.state.markerCount = 0
          self.state.lastMarkerLabel = nil
          self.state.audioLevelDB = -160
        }
        if let url {
          NSLog("[phospor] saved → \(url.path)")
          await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      } catch {
        NSLog("[phospor] failed to stop recording: \(error.localizedDescription)")
        await MainActor.run { self.state.phase = .recording }
      }
    }
  }

  /// NSWindow numbers we want excluded from the recording. Explicitly the
  /// control panel + source picker + outline overlay. The camera bubble is
  /// NOT excluded — it must appear in the recorded video so the user's
  /// webcam ends up baked into the screen track.
  private func excludedWindowNumbers() -> [Int] {
    var nums: [Int] = []
    if let n = controlPanel?.windowNumber { nums.append(n) }
    if let n = sourcePickerPanel?.windowNumber { nums.append(n) }
    // The outline window is owned by OutlineWindowController, not in
    // NSApp.windows directly until shown; iterate to find it by title.
    for w in NSApp.windows where w.isVisible {
      if w.title == "Phospor Outline", !nums.contains(w.windowNumber) {
        nums.append(w.windowNumber)
      }
    }
    return nums
  }

  private static func makeOutputURL() -> URL {
    let movies =
      FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
    let dir = movies.appendingPathComponent("Phospor", isDirectory: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let name = "Phospor-\(formatter.string(from: Date())).mp4"
    return dir.appendingPathComponent(name)
  }
}
