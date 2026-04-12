#!/usr/bin/env bash
# Builds Phospor as a .app bundle in build/Phospor.app
# Usage: ./scripts/build-app.sh [debug|release]   (default: debug)

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Phospor"
APP_DIR="$ROOT/build/$APP_NAME.app"
BIN_PATH="$ROOT/.build/$CONFIG/$APP_NAME"

cd "$ROOT"

echo "▶ Building ($CONFIG)..."
swift build -c "$CONFIG"

echo "▶ Assembling $APP_NAME.app..."
# Update in place when the bundle already exists so the path/inode stays
# stable — this gives TCC a better chance of remembering screen-recording
# permission across rebuilds.
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Sign with the stable "Phospor Dev" certificate if available — this keeps
# TCC permissions (screen recording, camera, mic) across rebuilds. Falls
# back to ad-hoc signing if the cert hasn't been set up yet.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Phospor Dev"; then
    codesign --force --sign "Phospor Dev" "$APP_DIR" >/dev/null 2>&1
else
    echo "⚠  No 'Phospor Dev' certificate — using ad-hoc signing."
    echo "   TCC permissions will reset on every rebuild."
    echo "   Run ./scripts/setup-cert.sh once to fix this."
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

# Touch the bundle so Finder/Launch Services notices changes
touch "$APP_DIR"

echo "✓ Built $APP_DIR"
echo "  Run with: open '$APP_DIR'"
