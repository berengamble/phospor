import AVFoundation
import CoreMedia
import Foundation

/// Thread-safe collection of `Marker`s for a single recording session.
/// Handles clock translation (wall-clock → media-relative), sidecar JSON
/// export, and embedded MP4 chapter track writing.
final class MarkerStore: @unchecked Sendable {
  private let lock = NSLock()
  private var markers: [Marker] = []

  /// Host-clock time (mach_continuous_time → seconds) captured at recording
  /// start. Used to translate wall-clock marker timestamps into media time.
  private let recordingStartDate: Date
  private let recordingStartMediaTime: CMTime

  /// Callback fired on the main actor whenever a marker is added.
  /// Used to drive the UI indicator.
  var onMarkerAdded: (@MainActor @Sendable (Marker) -> Void)?

  init(recordingStartDate: Date = Date(), recordingStartMediaTime: CMTime = .zero) {
    self.recordingStartDate = recordingStartDate
    self.recordingStartMediaTime = recordingStartMediaTime
  }

  /// Total markers recorded so far.
  var count: Int {
    lock.lock(); defer { lock.unlock() }
    return markers.count
  }

  /// All markers, sorted by media time.
  var allMarkers: [Marker] {
    lock.lock(); defer { lock.unlock() }
    return markers.sorted { $0.mediaTime < $1.mediaTime }
  }

  // MARK: - Adding markers

  /// Add a marker at the current wall-clock time.
  func add(kind: Marker.Kind, label: String) {
    let now = Date()
    let mediaSeconds = now.timeIntervalSince(recordingStartDate)
      + CMTimeGetSeconds(recordingStartMediaTime)
    let marker = Marker(
      kind: kind,
      mediaTime: max(0, mediaSeconds),
      wallClock: ISO8601DateFormatter().string(from: now),
      label: label
    )

    lock.lock()
    markers.append(marker)
    lock.unlock()

    let callback = onMarkerAdded
    Task { @MainActor in callback?(marker) }

    NSLog("[phospor] marker: \(marker.chapterTitle) @ \(String(format: "%.1f", marker.mediaTime))s")
  }

  /// Add a marker with an explicit wall-clock timestamp (from an external
  /// source like a Claude Code hook). `timestamp` is ISO-8601 or a Unix
  /// epoch seconds string.
  func add(kind: Marker.Kind, label: String, externalTimestamp: String) {
    let date: Date
    if let parsed = ISO8601DateFormatter().date(from: externalTimestamp) {
      date = parsed
    } else if let epoch = Double(externalTimestamp) {
      date = Date(timeIntervalSince1970: epoch)
    } else {
      date = Date() // fallback to now
    }

    let mediaSeconds = date.timeIntervalSince(recordingStartDate)
      + CMTimeGetSeconds(recordingStartMediaTime)
    let marker = Marker(
      kind: kind,
      mediaTime: max(0, mediaSeconds),
      wallClock: ISO8601DateFormatter().string(from: date),
      label: label
    )

    lock.lock()
    markers.append(marker)
    lock.unlock()

    let callback = onMarkerAdded
    Task { @MainActor in callback?(marker) }

    NSLog("[phospor] marker: \(marker.chapterTitle) @ \(String(format: "%.1f", marker.mediaTime))s")
  }

  // MARK: - Sidecar JSON

  /// Write the marker list as a JSON sidecar alongside the given video URL.
  /// E.g. `~/Movies/Phospor/Phospor-2026-04-16-120000.markers.json`.
  func writeSidecarJSON(for videoURL: URL) throws {
    let sorted = allMarkers
    guard !sorted.isEmpty else { return }

    let sidecarURL = videoURL.deletingPathExtension()
      .appendingPathExtension("markers")
      .appendingPathExtension("json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(sorted)
    try data.write(to: sidecarURL, options: .atomic)

    NSLog("[phospor] wrote \(sorted.count) markers → \(sidecarURL.lastPathComponent)")
  }

  // MARK: - Embedded MP4 chapter track

  /// Create an AVAssetWriterInput + adaptor pair for a timed-metadata
  /// (chapter) track. Caller adds the input to their AVAssetWriter before
  /// calling `startWriting()`.
  static func makeChapterInput() -> (
    input: AVAssetWriterInput, adaptor: AVAssetWriterInputMetadataAdaptor
  ) {
    // QuickTime chapter track uses the "common" key space with identifier
    // "mdta/com.apple.quicktime.title".
    let spec: [String: Any] = [
      kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
        "mdta/com.apple.quicktime.title",
      kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
        kCMMetadataBaseDataType_UTF8 as String,
    ]
    var desc: CMFormatDescription?
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
      allocator: kCFAllocatorDefault,
      metadataType: kCMMetadataFormatType_Boxed,
      metadataSpecifications: [spec] as CFArray,
      formatDescriptionOut: &desc
    )

    let input = AVAssetWriterInput(
      mediaType: .metadata,
      outputSettings: nil,
      sourceFormatHint: desc
    )
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    return (input, adaptor)
  }

  /// Write all collected markers into the chapter adaptor. Call this after
  /// the video/audio inputs are finished but BEFORE `finishWriting()`.
  func writeChapters(
    to adaptor: AVAssetWriterInputMetadataAdaptor,
    totalDuration: CMTime
  ) {
    let sorted = allMarkers
    guard !sorted.isEmpty else { return }

    for (i, marker) in sorted.enumerated() {
      let start = CMTime(seconds: marker.mediaTime, preferredTimescale: 600)
      let end: CMTime
      if i + 1 < sorted.count {
        end = CMTime(seconds: sorted[i + 1].mediaTime, preferredTimescale: 600)
      } else {
        end = totalDuration
      }
      let range = CMTimeRange(start: start, end: end)

      let item = AVMutableMetadataItem()
      item.identifier = .quickTimeMetadataTitle
      item.dataType = kCMMetadataBaseDataType_UTF8 as String
      item.value = marker.chapterTitle as NSString

      let group = AVTimedMetadataGroup(items: [item], timeRange: range)
      if adaptor.assetWriterInput.isReadyForMoreMediaData {
        adaptor.append(group)
      }
    }

    NSLog("[phospor] wrote \(sorted.count) chapter markers into mp4")
  }
}
