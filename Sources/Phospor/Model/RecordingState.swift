import Foundation
import Observation

@Observable
final class RecordingState {
  enum Phase: Equatable {
    case idle
    case armed  // source selected, ready to record
    case recording
    case stopping
  }

  var phase: Phase = .idle
  var cameraEnabled: Bool = false
  var microphoneEnabled: Bool = false

  /// Optional hint shown under the camera row — e.g. when permission is
  /// denied. `nil` when everything is fine.
  var cameraDeniedHint: String? = nil

  /// Optional hint shown under the microphone row when permission is denied.
  var microphoneDeniedHint: String? = nil

  /// Currently selected capture source. `nil` until the user picks one.
  var source: CaptureSource? {
    didSet {
      if source != nil, phase == .idle {
        phase = .armed
      }
    }
  }

  /// Human-readable label for the currently selected source.
  var sourceLabel: String {
    source?.title ?? "NO SOURCE"
  }

  var isRecording: Bool { phase == .recording }

  // MARK: - Markers (live during recording)

  /// Number of markers placed so far this recording.
  var markerCount: Int = 0
  /// Label of the most recent marker (for the UI flash).
  var lastMarkerLabel: String? = nil
  /// Current mic audio level in dB (updated during recording).
  var audioLevelDB: Float = -160
  /// Threshold in dB above which audio triggers speech markers.
  var audioThresholdDB: Float = -30

  /// Convenience for SwiftUI bindings that need CGFloat.
  var audioThresholdDBCG: CGFloat {
    get { CGFloat(audioThresholdDB) }
    set { audioThresholdDB = Float(newValue) }
  }
}
