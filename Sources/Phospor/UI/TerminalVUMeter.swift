import SwiftUI

/// Pure ASCII VU meter. Ten block characters, a level readout, and a
/// threshold stepper. Looks like it belongs in a 1985 mixing console.
///
///   ████░░░░░░  4   T▸5 [-][+]
///
struct TerminalVUMeter: View {
  let level: Int       // 0–9
  let threshold: Int   // 0–9
  var onThresholdChange: (Int) -> Void

  var body: some View {
    VStack(spacing: 6) {
      // Meter bar + readout
      HStack(spacing: 6) {
        Text(meterString)
          .font(Theme.mono(12, weight: .bold))
          .foregroundStyle(Theme.success)

        Text("\(level)")
          .font(Theme.mono(14, weight: .bold))
          .foregroundStyle(levelColor)
          .shadow(color: levelColor.opacity(level > 0 ? 0.6 : 0), radius: 4)
          .frame(width: 16, alignment: .trailing)
      }

      // Threshold control
      HStack(spacing: 6) {
        Text("THRESHOLD")
          .font(Theme.mono(8, weight: .bold))
          .kerning(1)
          .foregroundStyle(Theme.muted)

        Spacer()

        Button(action: { onThresholdChange(max(0, threshold - 1)) }) {
          Text("[-]")
            .font(Theme.mono(10, weight: .bold))
            .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)

        Text("\(threshold)")
          .font(Theme.mono(11, weight: .bold))
          .foregroundStyle(Theme.primary)
          .frame(width: 14, alignment: .center)

        Button(action: { onThresholdChange(min(9, threshold + 1)) }) {
          Text("[+]")
            .font(Theme.mono(10, weight: .bold))
            .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// Build the bar: `████░░░░░░`
  /// Blocks below threshold are green, at/above threshold are red.
  private var meterString: AttributedString {
    var result = AttributedString()
    for i in 0..<10 {
      var ch = AttributedString(i < level ? "█" : "░")
      if i < level {
        ch.foregroundColor = i >= threshold ? NSColor(Theme.danger) : NSColor(Theme.success)
      } else {
        ch.foregroundColor = NSColor(Theme.dim)
      }
      result += ch
    }
    return result
  }

  private var levelColor: Color {
    if level >= threshold { return Theme.danger }
    if level >= 4 { return Theme.primary }
    return Theme.success
  }
}
