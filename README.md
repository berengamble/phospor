# phospor

Lightweight macOS screen recorder with a Loom-style minimal control panel.
Built entirely with native APIs (`ScreenCaptureKit` + `AVFoundation` +
`SwiftUI`/`AppKit`), no third-party dependencies. Terminal-inspired UI
styled after the [mainframe](https://github.com/berengamble/mainframe)
project.

## Requirements

- macOS 14+
- Xcode command-line tools — `xcode-select --install` (Swift 5.9 toolchain)
- `openssl` (ships with macOS, used by the cert setup script)

## First-time setup

### 1. Clone

```sh
git clone https://github.com/berengamble/phospor.git
cd phospor
```

### 2. Create the code-signing certificate

macOS TCC (the permission system for Screen Recording, Camera, and
Microphone) keys on the binary's signing identity. Without a stable
certificate, permissions reset every time the binary is rebuilt.

Run this **once** — the certificate lives in your login keychain for
10 years:

```sh
./scripts/setup-cert.sh
```

You may be prompted for your macOS login password. If the automatic setup
fails, the script prints manual steps using Keychain Access.

### 3. Build & run

```sh
./scripts/build-app.sh          # debug build → build/Phospor.app
open build/Phospor.app
```

For a release build: `./scripts/build-app.sh release`.

### 4. Grant permissions

On first launch Phospor will request three macOS permissions. You can
grant each one as you need it:

| Permission | When prompted | Where to manage |
|---|---|---|
| **Screen Recording** | When you open the source picker | System Settings → Privacy & Security → Screen & System Audio Recording |
| **Camera** | When you toggle the camera ON | System Settings → Privacy & Security → Camera |
| **Microphone** | When you toggle the mic ON | System Settings → Privacy & Security → Microphone |

If a permission gets stuck (toggle shows ON but Phospor can't access it),
remove Phospor from that list, rebuild, and re-approve. With the signing
certificate in place this should only happen once.

## Usage

1. **Launch** Phospor — a floating control panel appears on the right edge
   of your main display.
2. **SOURCE** — click to pick a display or individual window. A cyan outline
   highlights the selected source.
3. **CAMERA** — toggle to show a draggable webcam bubble. It snaps to the
   nearest corner of the source and is baked into the recording.
4. **MICROPHONE** — toggle to record mic audio alongside the screen.
5. **START RECORDING** — captures screen + camera + mic to a single H.264
   mp4 at 60 fps. The control panel and outline are excluded from the
   capture.
6. **STOP RECORDING** — finalizes the file and reveals it in Finder at
   `~/Movies/Phospor/Phospor-YYYY-MM-DD-HHMMSS.mp4`.
7. **X** — quits the app.

## Project layout

```
Sources/Phospor/
├── App/        # @main entry, AppDelegate, window wiring
├── Capture/    # ScreenCaptureManager, CameraCaptureManager,
│               # AudioCaptureManager, RecordingWriter
├── Model/      # CaptureSource, RecordingState
└── UI/         # ControlPanelView, SourcePickerView,
                # OutlineWindowController, CameraBubbleWindowController,
                # Theme, TerminalComponents
Resources/
└── Info.plist  # bundle id, usage descriptions, LSUIElement
scripts/
├── build-app.sh     # swift build + .app assembly + codesign
└── setup-cert.sh    # one-time self-signed certificate creation
.github/workflows/
├── build.yml           # CI: lint, build, artifact upload, release attach
└── create-release.yml  # manual dispatch: semver bump → tag → release
```

## CI / releases

- **Every PR** triggers `build.yml` — lints with `swift-format` and builds
  a release `.app` bundle.
- **Manual releases** via `create-release.yml` — choose patch/minor/major,
  the workflow bumps the version, creates a tag + GitHub release, and
  attaches `Phospor.app.zip`.
- **Tag pushes** (`v1.2.3` or `1.2.3`) also trigger a build + release
  attach.
