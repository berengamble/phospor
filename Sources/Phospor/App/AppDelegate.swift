import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlPanel: NSPanel?
    private let state = RecordingState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showControlPanel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Control panel window

    private func showControlPanel() {
        if let existing = controlPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ControlPanelView(
            state: state,
            onClose: { [weak self] in self?.hideControlPanel() },
            onPickSource: { [weak self] in self?.handlePickSource() },
            onToggleRecord: { [weak self] in self?.handleToggleRecord() }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // Borderless floating panel — no titlebar, no traffic lights.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting

        // Center on the active screen with a slight rightward bias, like Loom.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = hosting.fittingSize == .zero ? NSSize(width: 320, height: 480) : hosting.fittingSize
            let origin = NSPoint(
                x: frame.maxX - size.width - 40,
                y: frame.midY - size.height / 2
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controlPanel = panel
    }

    private func hideControlPanel() {
        controlPanel?.orderOut(nil)
    }

    // MARK: - Actions (stubs for now)

    private func handlePickSource() {
        NSLog("[phospor] pick source — picker not yet implemented")
    }

    private func handleToggleRecord() {
        switch state.phase {
        case .idle, .armed:
            state.phase = .recording
        case .recording:
            state.phase = .idle
        case .stopping:
            break
        }
    }
}
