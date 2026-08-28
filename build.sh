#!/bin/bash
# Builds DeskStats.app into ./build. No Xcode project needed — just the CLT toolchain.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DeskStats.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework IOKit \
  Sources/Metrics.swift Sources/WidgetView.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/DeskStats"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DeskStats</string>
  <key>CFBundleDisplayName</key><string>DeskStats</string>
  <key>CFBundleIdentifier</key><string>com.brianfu.deskstats</string>
  <key>CFBundleExecutable</key><string>DeskStats</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Agent app: no Dock icon, no menu bar. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Ad-hoc signature so Gatekeeper and launchctl treat it as a stable identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built $APP"
