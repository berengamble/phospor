import SwiftUI

/// Mainframe-style terminal aesthetic.
/// Mirrors the color and type tokens from the mainframe project so Phospor
/// feels like a sibling tool: monospace, square borders, cyan-on-black.
enum Theme {
  // Backgrounds
  static let background = Color(red: 0.039, green: 0.039, blue: 0.039)  // #0a0a0a
  // rgba(0,20,20,0.85)
  static let panelBackground = Color(red: 0.0, green: 0.078, blue: 0.078).opacity(0.85)
  static let surface = Color.black.opacity(0.9)

  // Foregrounds
  static let primary = Color(red: 0.0, green: 1.0, blue: 1.0)  // #00ffff  cyan
  static let secondary = Color(red: 0.0, green: 0.8, blue: 0.8)  // #00cccc
  static let success = Color(red: 0.0, green: 1.0, blue: 0.0)  // #00ff00
  static let danger = Color(red: 1.0, green: 0.0, blue: 0.0)  // #ff0000
  static let muted = Color(red: 0.4, green: 0.4, blue: 0.4)  // #666666
  static let dim = Color(red: 0.2, green: 0.2, blue: 0.2)  // #333333

  // Type
  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  // Common metrics
  static let panelBorder: CGFloat = 2
  static let buttonBorder: CGFloat = 1
  static let glowRadius: CGFloat = 8
}
