import AVFoundation
import CoreMedia
import Foundation

/// Monitors mic audio levels and emits speech_start / speech_end markers
/// when the RMS level crosses a configurable dB threshold.
///
/// Designed to tap into the same `CMSampleBuffer` stream that
/// `AudioCaptureManager` already produces — call `process(_:)` from the
/// audio output delegate.
final class AudioLevelMonitor: @unchecked Sendable {
  private let markerStore: MarkerStore
  private let lock = NSLock()

  /// dB threshold; levels above this are considered "speech".
  private var thresholdDB: Float = -30

  /// Whether we're currently in a speech segment.
  private var isSpeaking = false

  /// Timestamp of when the level last dropped below threshold.
  /// We wait `silenceGracePeriod` before emitting speech_end to avoid
  /// flapping on brief pauses.
  private var silenceStartDate: Date?

  /// How long (seconds) the level must stay below threshold before we
  /// emit speech_end.
  private let silenceGracePeriod: TimeInterval = 1.5

  /// Callback to push the current dB level to the UI.
  var onLevelUpdate: (@MainActor @Sendable (Float) -> Void)?

  /// How often we push level updates to the UI (avoid flooding).
  private var lastUIUpdate: Date = .distantPast
  private let uiUpdateInterval: TimeInterval = 1.0 / 15.0  // ~15 fps

  init(markerStore: MarkerStore, thresholdDB: Float = -30) {
    self.markerStore = markerStore
    self.thresholdDB = thresholdDB
  }

  func updateThreshold(_ db: Float) {
    lock.lock(); defer { lock.unlock() }
    thresholdDB = db
  }

  /// Call this for every audio sample buffer from the mic.
  func process(_ sampleBuffer: CMSampleBuffer) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &length, dataPointerOut: &dataPointer
    )
    guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { return }

    // Compute RMS from the raw PCM samples. AudioCaptureManager's session
    // typically produces 32-bit float interleaved PCM.
    let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)?.pointee

    let db: Float
    if let asbd, asbd.mBitsPerChannel == 32,
      asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    {
      db = rmsDBFloat(ptr, byteCount: length)
    } else if let asbd, asbd.mBitsPerChannel == 16 {
      db = rmsDBInt16(ptr, byteCount: length)
    } else {
      // Unknown format — skip level analysis.
      return
    }

    // Push to UI at throttled rate.
    let now = Date()
    if now.timeIntervalSince(lastUIUpdate) >= uiUpdateInterval {
      lastUIUpdate = now
      let callback = onLevelUpdate
      Task { @MainActor in callback?(db) }
    }

    // Speech detection state machine.
    lock.lock()
    let threshold = thresholdDB
    let wasSpeaking = isSpeaking
    lock.unlock()

    if db >= threshold {
      lock.lock()
      silenceStartDate = nil
      if !isSpeaking {
        isSpeaking = true
        lock.unlock()
        markerStore.add(kind: .speechStart, label: "Audio detected")
      } else {
        lock.unlock()
      }
    } else if wasSpeaking {
      lock.lock()
      if silenceStartDate == nil {
        silenceStartDate = now
      }
      let elapsed = now.timeIntervalSince(silenceStartDate!)
      if elapsed >= silenceGracePeriod {
        isSpeaking = false
        silenceStartDate = nil
        lock.unlock()
        markerStore.add(kind: .speechEnd, label: "Silence")
      } else {
        lock.unlock()
      }
    }
  }

  // MARK: - RMS computation

  private func rmsDBFloat(_ ptr: UnsafeMutablePointer<Int8>, byteCount: Int) -> Float {
    let floatPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
    let count = byteCount / MemoryLayout<Float>.size
    guard count > 0 else { return -160 }
    var sum: Float = 0
    for i in 0..<count {
      let s = floatPtr[i]
      sum += s * s
    }
    let rms = sqrt(sum / Float(count))
    return rms > 0 ? 20 * log10(rms) : -160
  }

  private func rmsDBInt16(_ ptr: UnsafeMutablePointer<Int8>, byteCount: Int) -> Float {
    let int16Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Int16.self)
    let count = byteCount / MemoryLayout<Int16>.size
    guard count > 0 else { return -160 }
    var sum: Float = 0
    for i in 0..<count {
      let s = Float(int16Ptr[i]) / Float(Int16.max)
      sum += s * s
    }
    let rms = sqrt(sum / Float(count))
    return rms > 0 ? 20 * log10(rms) : -160
  }
}
