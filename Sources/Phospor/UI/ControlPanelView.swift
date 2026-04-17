import SwiftUI

struct ControlPanelView: View {
  @Bindable var state: RecordingState
  var onClose: () -> Void
  var onPickSource: () -> Void
  var onToggleRecord: () -> Void
  var onToggleCamera: () -> Void
  var onToggleMicrophone: () -> Void

  var body: some View {
    TerminalPanel(header: "PHOSPOR // REC") {
      VStack(spacing: 14) {
        headerRow

        TerminalRow(
          icon: "display",
          title: "SOURCE",
          subtitle: state.sourceLabel,
          action: onPickSource
        ) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.secondary)
        }

        TerminalRow(
          icon: state.cameraEnabled ? "video.fill" : "video.slash.fill",
          title: state.cameraEnabled ? "CAMERA" : "NO CAMERA",
          subtitle: state.cameraDeniedHint,
          action: onToggleCamera
        ) {
          TerminalPill(
            text: state.cameraEnabled ? "ON" : "OFF",
            color: state.cameraEnabled ? Theme.success : Theme.danger
          )
        }

        TerminalRow(
          icon: state.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
          title: state.microphoneEnabled ? "MICROPHONE" : "NO MICROPHONE",
          subtitle: state.microphoneDeniedHint,
          action: onToggleMicrophone
        ) {
          TerminalPill(
            text: state.microphoneEnabled ? "ON" : "OFF",
            color: state.microphoneEnabled ? Theme.success : Theme.danger
          )
        }

        TerminalButton(
          title: state.isRecording ? "STOP RECORDING" : "START RECORDING",
          variant: state.isRecording ? .danger : .success,
          icon: state.isRecording ? "stop.fill" : "record.circle",
          action: onToggleRecord
        )
        .frame(maxWidth: .infinity)

        if state.isRecording {
          markerIndicators
        }

        statusLine
      }
    }
    .padding(14)
    .background(Theme.background)
    .frame(width: 320)
  }

  private var headerRow: some View {
    HStack {
      HStack(spacing: 6) {
        Circle()
          .fill(state.isRecording ? Theme.danger : Theme.primary)
          .frame(width: 8, height: 8)
          .shadow(color: state.isRecording ? Theme.danger : Theme.primary, radius: 4)
        Text(state.isRecording ? "REC" : "READY")
          .font(Theme.mono(10, weight: .bold))
          .kerning(1)
          .foregroundStyle(state.isRecording ? Theme.danger : Theme.primary)
      }
      Spacer()
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Theme.secondary)
          .padding(6)
          .overlay(Rectangle().stroke(Theme.secondary, lineWidth: 1))
      }
      .buttonStyle(.plain)
    }
  }

  private var markerIndicators: some View {
    VStack(spacing: 8) {
      // VU meter with threshold control
      if state.microphoneEnabled {
        TerminalVUMeter(
          level: dbToLevel(state.audioLevelDB),
          threshold: dbToLevel(state.audioThresholdDB),
          onThresholdChange: { newLevel in
            state.audioThresholdDB = levelToDB(newLevel)
          }
        )
      }

      // Marker count + last marker
      HStack(spacing: 8) {
        Image(systemName: "bookmark.fill")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Theme.primary)
        Text("MARKERS: \(state.markerCount)")
          .font(Theme.mono(9, weight: .bold))
          .kerning(1)
          .foregroundStyle(Theme.primary)
        Spacer()
      }
      if let label = state.lastMarkerLabel {
        Text(label)
          .font(Theme.mono(8))
          .foregroundStyle(Theme.muted)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .overlay(Rectangle().stroke(Theme.dim, lineWidth: 1))
  }

  /// Map dB (-60…0) to 0–9 scale.
  private func dbToLevel(_ db: Float) -> Int {
    let clamped = max(-60, min(0, db))
    return Int(((clamped + 60) / 60) * 9)
  }

  /// Map 0–9 scale back to dB.
  private func levelToDB(_ level: Int) -> Float {
    (Float(level) / 9.0 * 60.0) - 60.0
  }

  private var statusLine: some View {
    HStack {
      Text("MEM: 640K OK")
      Spacer()
      Text("v0.1.0")
    }
    .font(Theme.mono(9))
    .foregroundStyle(Theme.muted)
    .padding(.top, 4)
    .overlay(
      Rectangle().fill(Theme.dim).frame(height: 1),
      alignment: .top
    )
    .padding(.top, 6)
  }
}
