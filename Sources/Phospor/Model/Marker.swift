import CoreMedia
import Foundation

/// A single marker event recorded during a session.
struct Marker: Codable, Sendable {
  enum Kind: String, Codable, Sendable {
    case claudeStart = "claude_start"
    case claudeStop = "claude_stop"
    case speechStart = "speech_start"
    case speechEnd = "speech_end"
    case manual = "manual"
  }

  let kind: Kind
  /// Seconds from the start of the recording.
  let mediaTime: Double
  /// Wall-clock ISO-8601 timestamp of the event.
  let wallClock: String
  /// Human-readable label for the chapter track.
  let label: String

  /// Pretty chapter name with a bracketed type prefix.
  var chapterTitle: String {
    let tag: String
    switch kind {
    case .claudeStart: tag = "CLAUDE START"
    case .claudeStop: tag = "CLAUDE STOP"
    case .speechStart: tag = "SPEECH START"
    case .speechEnd: tag = "SPEECH END"
    case .manual: tag = "MARKER"
    }
    return "[\(tag)] \(label)"
  }
}
