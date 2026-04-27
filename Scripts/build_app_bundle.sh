#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${PDFF_VERSION:-0.1}"
BUILD_NUMBER="${PDFF_BUILD_NUMBER:-1}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ ! -f Assets/AppIcon.icns ]; then
  swift Scripts/generate_app_icon.swift Assets/AppIcon.iconset
  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
fi

APP_DIR=".build/Pdff.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/pdff" "$APP_DIR/Contents/MacOS/pdff"
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string pdff" \
  -c "Add :CFBundleIdentifier string com.pdff.local" \
  -c "Add :CFBundleName string pdff" \
  -c "Add :CFBundleDisplayName string pdff" \
  -c "Add :CFBundleIconFile string AppIcon" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleVersion string $BUILD_NUMBER" \
  -c "Add :CFBundleShortVersionString string $VERSION" \
  "$APP_DIR/Contents/Info.plist"

echo "$APP_DIR"
