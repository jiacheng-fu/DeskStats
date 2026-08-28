#!/bin/bash
# Installs DeskStats into ~/Applications and registers it as a login agent.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.brianfu.deskstats"
DEST="$HOME/Applications/DeskStats.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

# Replace any running copy.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "DeskStats.app/Contents/MacOS/DeskStats" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/DeskStats.app "$DEST"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/DeskStats</string></array>
  <!-- Start at login, and only at login. -->
  <key>RunAtLoad</key><true/>
  <!-- Come back if it ever crashes, but respect a deliberate Quit. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <!-- Background type: the scheduler may throttle us freely. -->
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PL

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed  -> $DEST"
echo "login agent-> $PLIST"
