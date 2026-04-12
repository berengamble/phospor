import Foundation
import ScreenCaptureKit
import CoreGraphics

/// A user-pickable capture source: either an entire display or a single window.
enum CaptureSource: Identifiable, Hashable {
    case display(SCDisplay)
    case window(SCWindow)

    var id: String {
        switch self {
        case .display(let d): return "display-\(d.displayID)"
        case .window(let w):  return "window-\(w.windowID)"
        }
    }

    /// Primary label shown in the picker / control panel.
    var title: String {
        switch self {
        case .display(let d):
            return "DISPLAY \(d.displayID) — \(d.width)×\(d.height)"
        case .window(let w):
            let title = w.title?.trimmingCharacters(in: .whitespaces) ?? ""
            return title.isEmpty ? "UNTITLED WINDOW" : title
        }
    }

    /// Secondary, smaller label.
    var subtitle: String {
        switch self {
        case .display(let d):
            return "\(d.width)×\(d.height) @ \(d.frame.origin.x.formatted()),\(d.frame.origin.y.formatted())"
        case .window(let w):
            return w.owningApplication?.applicationName ?? "—"
        }
    }

    /// On-screen frame of the source in global coordinates (CoreGraphics flipped).
    var frame: CGRect {
        switch self {
        case .display(let d): return d.frame
        case .window(let w):  return w.frame
        }
    }

    // MARK: Hashable

    static func == (lhs: CaptureSource, rhs: CaptureSource) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
