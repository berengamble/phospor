import Foundation
import AVFoundation
import AppKit

/// Wraps AVCaptureSession for the live webcam preview rendered inside the
/// camera bubble window. Recording itself is handled by ScreenCaptureKit —
/// this manager only feeds the preview layer.
///
/// Public API is callable from any thread; all `AVCaptureSession` mutation
/// happens on a dedicated serial queue so we never touch the session from
/// the main thread (which would block UI on `startRunning`).
final class CameraCaptureManager: NSObject, @unchecked Sendable {
    static let shared = CameraCaptureManager()
    private override init() { super.init() }

    private let sessionQueue = DispatchQueue(label: "phospor.camera.session")
    private let session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?

    private(set) var currentDevice: AVCaptureDevice?

    /// Whether the capture session is currently running. Cheap, thread-safe.
    var isRunning: Bool { session.isRunning }

    // MARK: - Permission

    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Returns true if permission is currently granted (or becomes granted
    /// after the first-run prompt is approved). Does NOT re-prompt if
    /// previously denied — the user has to flip the toggle in System Settings.
    func requestPermission() async -> Bool {
        switch authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Devices

    func availableDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .deskViewCamera,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    func defaultDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
            ?? availableDevices().first
    }

    // MARK: - Session lifecycle

    /// Start the capture session with the given device (or default if nil).
    /// Idempotent. Errors are logged; the bubble UI shows a placeholder when
    /// configuration fails.
    func start(with device: AVCaptureDevice? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureLocked(with: device)
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Must be called on `sessionQueue`.
    private func configureLocked(with requested: AVCaptureDevice?) {
        let target = requested ?? currentDevice ?? defaultDevice()
        guard let target else {
            NSLog("[phospor] camera: no video device available")
            return
        }

        // Already configured for this device; nothing to do.
        if currentDevice?.uniqueID == target.uniqueID, currentInput != nil {
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: target)
            guard session.canAddInput(input) else {
                NSLog("[phospor] camera: cannot add input for \(target.localizedName)")
                return
            }
            session.addInput(input)
            currentInput = input
            currentDevice = target
        } catch {
            NSLog("[phospor] camera: failed to create input — \(error.localizedDescription)")
            return
        }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
    }

    // MARK: - Preview layer

    /// Construct a preview layer bound to the underlying session. Caller adds
    /// it to a view's layer hierarchy and sizes it.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}
