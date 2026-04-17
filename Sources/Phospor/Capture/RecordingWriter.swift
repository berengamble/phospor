import AVFoundation
import CoreMedia
import Foundation

/// Thin wrapper around `AVAssetWriter` with one H.264 video input and an
/// optional AAC audio input. Receives `CMSampleBuffer`s straight from the
/// ScreenCaptureKit / AVCaptureSession output queues.
final class RecordingWriter: @unchecked Sendable {
  let outputURL: URL

  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput?
  private let chapterAdaptor: AVAssetWriterInputMetadataAdaptor?
  private var sessionStarted = false
  private var sessionStartTime: CMTime = .zero
  private var lastVideoPTS: CMTime = .zero
  private let lock = NSLock()

  init(outputURL: URL, width: Int, height: Int, includeAudio: Bool) throws {
    // Ensure parent dir exists.
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    self.outputURL = outputURL
    self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

    // ----- Video input -----
    let pixelCount = Double(width * height)
    let bitRate = Int(min(pixelCount * 8.0, 40_000_000))  // cap 40 Mbps

    let compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitRate,
      AVVideoMaxKeyFrameIntervalKey: 60,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoAllowFrameReorderingKey: false,
    ]
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]

    let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    vInput.expectsMediaDataInRealTime = true
    self.videoInput = vInput

    guard writer.canAdd(vInput) else {
      throw NSError(
        domain: "phospor.writer",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter rejected video input"]
      )
    }
    writer.add(vInput)

    // ----- Audio input (optional) -----
    if includeAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 2,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: 128_000,
      ]
      let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      aInput.expectsMediaDataInRealTime = true
      if writer.canAdd(aInput) {
        writer.add(aInput)
        self.audioInput = aInput
      } else {
        NSLog("[phospor] writer: audio input rejected, recording video only")
        self.audioInput = nil
      }
    } else {
      self.audioInput = nil
    }

    // ----- Chapter (metadata) input -----
    let (chapterInput, chAdaptor) = MarkerStore.makeChapterInput()
    if writer.canAdd(chapterInput) {
      writer.add(chapterInput)
      self.chapterAdaptor = chAdaptor
    } else {
      NSLog("[phospor] writer: chapter input rejected")
      self.chapterAdaptor = nil
    }

    guard writer.startWriting() else {
      throw writer.error
        ?? NSError(
          domain: "phospor.writer",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "startWriting() returned false"]
        )
    }
  }

  /// Append a video sample buffer. Safe to call from any thread.
  /// The first video sample also starts the writer session.
  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    lock.lock()
    if !sessionStarted {
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      writer.startSession(atSourceTime: pts)
      sessionStartTime = pts
      sessionStarted = true
    }
    let ready = videoInput.isReadyForMoreMediaData
    lock.unlock()

    if ready {
      videoInput.append(sampleBuffer)
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      lock.lock()
      lastVideoPTS = pts
      lock.unlock()
    }
  }

  /// Append an audio sample buffer. Safe to call from any thread.
  /// Drops samples that arrive before the first video frame, since
  /// `AVAssetWriter` rejects anything earlier than the session start time.
  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard let audioInput else { return }
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    lock.lock()
    let started = sessionStarted
    let startTime = sessionStartTime
    lock.unlock()

    guard started else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if CMTimeCompare(pts, startTime) < 0 {
      return  // pre-session audio, drop it
    }

    if audioInput.isReadyForMoreMediaData {
      audioInput.append(sampleBuffer)
    }
  }

  /// Flush chapters + finalize. Returns the output URL when finished.
  func finish(markerStore: MarkerStore?) async -> URL {
    // Write chapter markers into the metadata track before finishing.
    if let adaptor = chapterAdaptor, let store = markerStore {
      let duration = currentDuration()
      store.writeChapters(to: adaptor, totalDuration: duration)
    }

    markInputsFinished()
    await writer.finishWriting()

    // Write sidecar JSON alongside the mp4.
    if let store = markerStore {
      try? store.writeSidecarJSON(for: outputURL)
    }

    return outputURL
  }

  private func markInputsFinished() {
    lock.lock()
    defer { lock.unlock() }
    videoInput.markAsFinished()
    audioInput?.markAsFinished()
    chapterAdaptor?.assetWriterInput.markAsFinished()
  }

  private func currentDuration() -> CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTimeSubtract(lastVideoPTS, sessionStartTime)
  }
}
