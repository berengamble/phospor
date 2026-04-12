import AVFoundation
import CoreMedia
import Foundation

/// Wraps AVCaptureSession to capture microphone audio. Forwards each
/// `CMSampleBuffer` to whoever installs a sink (typically the
/// `RecordingWriter`).
///
/// All session mutation happens on a dedicated serial queue — this manager
/// is `@unchecked Sendable` and safe to call from any thread.
final class AudioCaptureManager: NSObject, @unchecked Sendable {
  static let shared = AudioCaptureManager()
  private override init() { super.init() }

  private let sessionQueue = DispatchQueue(label: "phospor.audio.session")
  private let outputQueue = DispatchQueue(label: "phospor.audio.output")
  private let session = AVCaptureSession()
  private var currentInput: AVCaptureDeviceInput?
  private let audioOutput = AVCaptureAudioDataOutput()

  /// Set by `start(handler:)` and cleared by `stop()`. The output delegate
  /// reads it on the audio queue and forwards each sample buffer.
  private let sinkLock = NSLock()
  private var sink: ((CMSampleBuffer) -> Void)?

  var isRunning: Bool { session.isRunning }

  // MARK: - Permission

  func authorizationStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  func requestPermission() async -> Bool {
    switch authorizationStatus() {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  // MARK: - Devices

  func availableDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    ).devices
  }

  func defaultDevice() -> AVCaptureDevice? {
    AVCaptureDevice.default(for: .audio) ?? availableDevices().first
  }

  // MARK: - Session lifecycle

  /// Start capturing mic audio. The handler is invoked on a private serial
  /// queue for every audio sample buffer; it must be reentrant-safe and
  /// fast.
  func start(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
    sinkLock.lock()
    sink = handler
    sinkLock.unlock()

    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.configureLocked()
      if !self.session.isRunning {
        self.session.startRunning()
      }
    }
  }

  func stop() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.session.isRunning {
        self.session.stopRunning()
      }
      self.sinkLock.lock()
      self.sink = nil
      self.sinkLock.unlock()
    }
  }

  /// Must be called on `sessionQueue`.
  private func configureLocked() {
    guard let device = defaultDevice() else {
      NSLog("[phospor] audio: no microphone device available")
      return
    }

    // Already configured for the same device.
    if let existing = currentInput, existing.device.uniqueID == device.uniqueID {
      return
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    if let existing = currentInput {
      session.removeInput(existing)
      currentInput = nil
    }

    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        NSLog("[phospor] audio: cannot add input for \(device.localizedName)")
        return
      }
      session.addInput(input)
      currentInput = input
    } catch {
      NSLog("[phospor] audio: failed to create input — \(error.localizedDescription)")
      return
    }

    if !session.outputs.contains(audioOutput) {
      audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
      if session.canAddOutput(audioOutput) {
        session.addOutput(audioOutput)
      } else {
        NSLog("[phospor] audio: cannot add audio data output")
      }
    }
  }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioCaptureManager: AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    sinkLock.lock()
    let handler = sink
    sinkLock.unlock()
    handler?(sampleBuffer)
  }
}
