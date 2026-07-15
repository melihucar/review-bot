#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Review Bot"
APP_DIR="$ROOT/dist/$APP_NAME.app"
VERSION="${1:-dev}"
CLEAN_VERSION="${VERSION#v}"
STAGING="$ROOT/dist/dmg-staging"
DMG="$ROOT/dist/ReviewBot-$CLEAN_VERSION.dmg"

if [ ! -d "$APP_DIR" ]; then
	echo "Missing $APP_DIR — run 'make app' first (or 'make dmg')." >&2
	exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
	-volname "$APP_NAME" \
	-srcfolder "$STAGING" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	"$DMG" >/dev/null

rm -rf "$STAGING"

echo "Built: $DMG"
