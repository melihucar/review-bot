#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Review Bot"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

cd "$ROOT"
swift build -c release --product ReviewBot
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/ReviewBot" "$MACOS_DIR/ReviewBot"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/ReviewBot"

# Stamp the release version (e.g. from a git tag) before signing so the
# signature stays valid. Accepts "1.2.3" or "v1.2.3".
if [ -n "${APP_VERSION:-}" ]; then
	CLEAN_VERSION="${APP_VERSION#v}"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CLEAN_VERSION" "$CONTENTS_DIR/Info.plist"
fi

codesign --force --deep --sign "$IDENTITY" "$APP_DIR"

echo "Built: $APP_DIR"
echo "Move Review Bot.app to /Applications, then open it from Finder."
