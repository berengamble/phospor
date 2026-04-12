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

    /// Human-readable label for the currently selected source. Real source
    /// model lands when ScreenCaptureManager comes online.
    var sourceLabel: String = "FULL SCREEN"

    var isRecording: Bool { phase == .recording }
}
