import Foundation
import ScreenCaptureKit

/// Wraps ScreenCaptureKit for source enumeration and recording.
/// Phase 1: stub. Real implementation lands in Phase 2.
@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private init() {}

    func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
}
