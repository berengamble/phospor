import SwiftUI

struct ControlPanelView: View {
    @Bindable var state: RecordingState
    var onClose: () -> Void
    var onPickSource: () -> Void
    var onToggleRecord: () -> Void

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
                    action: { state.cameraEnabled.toggle() }
                ) {
                    TerminalPill(
                        text: state.cameraEnabled ? "ON" : "OFF",
                        color: state.cameraEnabled ? Theme.success : Theme.danger
                    )
                }

                TerminalRow(
                    icon: state.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
                    title: state.microphoneEnabled ? "MICROPHONE" : "NO MICROPHONE",
                    action: { state.microphoneEnabled.toggle() }
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
