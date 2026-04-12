import Foundation
import Observation

@Observable
final class RecordingState {
    enum Phase: Equatable {
        case idle
        case armed       // source selected, ready to record
        case recording
        case stopping
    }

    var phase: Phase = .idle
    var cameraEnabled: Bool = false
    var microphoneEnabled: Bool = false

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
}
