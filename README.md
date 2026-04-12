# phospor

Lightweight macOS screen recorder. Loom-style minimal control panel, native
APIs only (`ScreenCaptureKit` + `AVFoundation` + `SwiftUI`/`AppKit`), no
third-party dependencies.

## Requirements

- macOS 14+
- Xcode command line tools (`xcode-select --install`) — Swift 5.9 toolchain

## Build & run

```sh
./scripts/build-app.sh         # debug build, produces build/Phospor.app
open build/Phospor.app
```

For a release build: `./scripts/build-app.sh release`.

The script compiles via `swift build`, assembles a `.app` bundle around the
binary, and ad-hoc code-signs it so macOS TCC has a stable identity for
camera / microphone / screen-recording prompts.

## Layout

```
Sources/Phospor/
├── App/        # @main entry, AppDelegate, window wiring
├── Capture/    # ScreenCaptureKit + AVFoundation managers
├── Model/      # Observable recording state
└── UI/         # SwiftUI views (terminal-style theme)
Resources/
└── Info.plist  # bundle id, usage descriptions, LSUIElement
scripts/
└── build-app.sh
```

## Status

**Phase 1** — scaffold + floating control panel UI ✅
**Phase 2** — display/window enumeration + selection outline (next)
**Phase 3** — draggable webcam bubble
**Phase 4** — recording pipeline (SCStream → AVAssetWriter → mp4)
**Phase 5** — mic, timer, save flow
