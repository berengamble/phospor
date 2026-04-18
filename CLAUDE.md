# CLAUDE.md — Phospor

## What is this?

Phospor is a lightweight macOS screen recorder (Loom-style), built entirely
with native Swift APIs. Zero external dependencies. The UI uses a retro
terminal aesthetic borrowed from the user's other project `../mainframe`
(cyan on black, monospace, square borders, glow).

## Tech stack

- **Swift 5.9** / **macOS 14+** (Sonoma)
- **ScreenCaptureKit** — display/window capture via `SCStream`
- **AVFoundation** — webcam (`AVCaptureSession`), mic (`AVCaptureAudioDataOutput`), recording (`AVAssetWriter` with H.264 video + AAC audio)
- **SwiftUI** — control panel UI
- **AppKit** — borderless `NSPanel` windows (control panel, source picker, outline overlay, camera bubble)
- **Network.framework** — `NWListener` for the marker HTTP endpoint
- **No Xcode project** — pure SwiftPM executable, wrapped into a `.app` bundle by `scripts/build-app.sh`

## Build & run

```sh
./scripts/setup-cert.sh          # one-time: self-signed "Phospor Dev" cert for stable TCC
./scripts/build-app.sh            # debug build → build/Phospor.app
./scripts/build-app.sh release    # release build
open build/Phospor.app
```

The build script runs `swift build`, copies the binary + `Resources/Info.plist` into a `.app` bundle, and code-signs with the "Phospor Dev" certificate (falls back to ad-hoc if the cert isn't set up). The cert is critical — without it, macOS TCC resets Screen Recording / Camera / Mic permissions on every rebuild.

## Architecture

### App lifecycle (`Sources/Phospor/App/`)

- `PhosporApp.swift` — `@main` entry, no main window, delegates to `AppDelegate`
- `AppDelegate.swift` — creates the floating control panel `NSPanel`, manages all window lifecycle, orchestrates recording start/stop, wires up the camera bubble, marker server, audio monitor. This is the central coordinator.

### Capture pipeline (`Sources/Phospor/Capture/`)

- `ScreenCaptureManager.swift` — singleton wrapping `SCStream`. Handles source enumeration (`SCShareableContent`), filter construction (`SCContentFilter`), and the `SCStreamOutput` delegate that feeds video frames to the writer. For display sources, uses `excludingWindows:` filter. For window sources, uses `display + including:[target, bubble] + sourceRect` so the camera bubble appears in window recordings.
- `RecordingWriter.swift` — wraps `AVAssetWriter` with three inputs: H.264 video, optional AAC audio, and a timed metadata track for chapter markers. Uses `movieFragmentInterval = 10s` so recordings survive crashes. The `finish(markerStore:)` method flushes chapters into the metadata track and writes a sidecar JSON before finalizing.
- `CameraCaptureManager.swift` — `AVCaptureSession` on a dedicated serial queue for the webcam. Produces an `AVCaptureVideoPreviewLayer` that the bubble window hosts. Not `@MainActor` — session ops happen on `sessionQueue`.
- `AudioCaptureManager.swift` — `AVCaptureSession` for mic input. Forwards `CMSampleBuffer`s via a sink closure to whoever owns the writer. Same queue pattern as camera.
- `AudioLevelMonitor.swift` — computes RMS dB from mic sample buffers, fires `speech_start` / `speech_end` markers when level crosses a configurable threshold (with 1.5s silence grace to avoid flapping). Pushes level updates to the UI at ~15 fps.
- `MarkerStore.swift` — thread-safe collection of `Marker` events. Handles clock translation (wall-clock → media-relative), writes sidecar `.markers.json` incrementally after each marker, and flushes embedded MP4 chapter markers via `AVAssetWriterInputMetadataAdaptor` on finish.
- `MarkerServer.swift` — `NWListener` on localhost:19850 accepting `POST /marker`. Accepts both Phospor's format `{"event":"claude_start"}` and Claude Code's hook format `{"hook_event_name":"UserPromptSubmit"}`. Writes the port to `~/Library/Application Support/Phospor/marker-port` so hooks can discover it. Only active during recording.

### Model (`Sources/Phospor/Model/`)

- `RecordingState.swift` — `@Observable` state object driving all UI. Properties: `phase` (idle/armed/recording/stopping), `source`, `cameraEnabled`, `microphoneEnabled`, `markerCount`, `lastMarkerLabel`, `audioLevelDB`, `audioThresholdDB`, and permission denial hints.
- `CaptureSource.swift` — enum wrapping `SCDisplay` or `SCWindow` with computed `title`, `subtitle`, `frame`, and `Hashable`/`Identifiable` conformance.
- `Marker.swift` — `Codable` struct with `kind` (claude_start/stop, speech_start/stop, manual), `mediaTime`, `wallClock`, `label`, and a `chapterTitle` for the MP4 track.

### UI (`Sources/Phospor/UI/`)

- `Theme.swift` — color and typography tokens mirroring mainframe's terminal aesthetic. All colors: `primary` (#00ffff cyan), `secondary` (#00cccc), `success` (#00ff00), `danger` (#ff0000), `muted` (#666), `dim` (#333), `background` (#0a0a0a). Font: system monospaced (SF Mono).
- `TerminalComponents.swift` — reusable SwiftUI components: `TerminalPanel` (bordered box with header), `TerminalButton` (bordered button with variants), `TerminalRow` (icon + title + subtitle + trailing), `TerminalPill` (small status badge).
- `ControlPanelView.swift` — main UI. Source row, camera toggle, mic toggle, start/stop button. During recording shows the VU meter and marker indicators.
- `SourcePickerView.swift` — lists displays + windows from `SCShareableContent`. Supports pre-fetched sources to avoid loading flash. Handles permission-denied state with an "OPEN SETTINGS" button.
- `OutlineWindowController.swift` — borderless transparent `NSWindow` drawing a cyan rounded outline around the selected source. Polls `CGWindowListCopyWindowInfo` at 30 Hz for window sources so the outline tracks window movement.
- `CameraBubbleWindowController.swift` — circular borderless `NSPanel` hosting the webcam preview layer. Constrained inside the source bounds with 16pt padding. Snaps to nearest corner on drag release with spring animation. The bubble is NOT excluded from `SCContentFilter` so it appears in recordings.
- `TerminalVUMeter.swift` — 10-segment ASCII block meter (`████░░░░░░`) with color coding (green below threshold, red above) and a `[-][+]` threshold stepper.

### Scripts

- `scripts/build-app.sh` — compiles, assembles `.app` bundle, code-signs
- `scripts/setup-cert.sh` — creates self-signed "Phospor Dev" certificate in login keychain
- `scripts/install-hooks.sh` — writes Claude Code `UserPromptSubmit` + `Stop` hooks into `~/.claude/settings.json`

### CI (`.github/workflows/`)

- `build.yml` — lint (`swift-format`), build, zip `.app`, upload artifact, attach to release on tag push
- `create-release.yml` — manual dispatch, semver bump, tag + release creation, triggers build

## Key design decisions

1. **No Xcode project.** Pure SwiftPM executable wrapped into `.app` by a shell script. Avoids binary `project.pbxproj` in source control.
2. **Camera baked into screen track.** The webcam bubble is a floating `NSWindow` captured naturally by ScreenCaptureKit as part of the screen. No separate camera track or compositing pipeline. User can drag the bubble during recording. The control panel, outline, and picker are excluded from capture; the bubble is not.
3. **Window source filter trick.** For window sources, uses `SCContentFilter(display:including:[targetWindow, cameraBubble])` with `sourceRect` cropping instead of `desktopIndependentWindow`, so the camera bubble appears in window recordings.
4. **Fragmented MP4.** `movieFragmentInterval = 10s` on `AVAssetWriter` so the file is recoverable (loses max 10s) if the process is killed mid-recording.
5. **Incremental marker sidecar.** The `.markers.json` is flushed after every marker event, not just on recording stop. Combined with fragmented MP4, both video and markers survive crashes.
6. **TCC signing.** A self-signed "Phospor Dev" certificate gives a stable designated requirement so macOS TCC permissions persist across rebuilds. Without it, every `swift build` changes the cdhash and TCC silently revokes grants.
7. **Source picker as child window.** Uses `NSWindow.addChildWindow` so the picker follows the control panel when dragged. Sources are pre-fetched before the panel appears to avoid loading flash.

## Threading model

- `ScreenCaptureManager`, `AudioCaptureManager`, `CameraCaptureManager` are all `@unchecked Sendable` with internal serial queues. They are NOT `@MainActor`.
- `RecordingWriter` and `MarkerStore` are `@unchecked Sendable` with `NSLock` for thread safety.
- `AppDelegate`, all window controllers, and all UI code are `@MainActor`.
- `SCStreamOutput` callback runs on `ScreenCaptureManager.outputQueue`. Audio delegate runs on `AudioCaptureManager.outputQueue`. Both feed the writer directly from their queues.

## Output format

Recordings land at `~/Movies/Phospor/Phospor-YYYY-MM-DD-HHMMSS.mp4` with:
- Stream 0: H.264 video (up to 60 fps, bitrate capped at 40 Mbps)
- Stream 1: AAC audio (128 kbps, 44.1 kHz stereo) — if mic was enabled
- Stream 2: Timed metadata (`mebx`) — chapter markers
- Sidecar: `.markers.json` alongside the mp4

## Formatting

The codebase uses `swift-format` with 2-space indentation. CI enforces this via `swift-format lint --strict --recursive Sources`.

## Deferred backlog

- **Permissions onboarding flow** — guided first-launch screen walking user through TCC grants with live status indicators
- **Dynamic sourceRect tracking** — poll window position during recording and update `SCStream.updateConfiguration` so window-source recordings follow window movement (currently the sourceRect is fixed at recording start)
- **System audio capture** — `SCStreamConfiguration.capturesAudio` for recording app audio alongside mic
