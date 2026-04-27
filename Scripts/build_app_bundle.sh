#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build

if [ ! -f Assets/AppIcon.icns ]; then
  swift Scripts/generate_app_icon.swift Assets/AppIcon.iconset
  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
fi

APP_DIR=".build/Pdff.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/arm64-apple-macosx/debug/pdff "$APP_DIR/Contents/MacOS/pdff"
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string pdff" \
  -c "Add :CFBundleIdentifier string com.pdff.local" \
  -c "Add :CFBundleName string pdff" \
  -c "Add :CFBundleDisplayName string pdff" \
  -c "Add :CFBundleIconFile string AppIcon" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleVersion string 1" \
  -c "Add :CFBundleShortVersionString string 0.1" \
  "$APP_DIR/Contents/Info.plist"

echo "$APP_DIR"
