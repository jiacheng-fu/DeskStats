#!/bin/bash
# Removes everything install.sh put on the system. Leaves this source tree alone.
set -uo pipefail

LABEL="com.brianfu.deskstats"
APP="$HOME/Applications/DeskStats.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CMD="$HOME/.local/bin/stats"

say() { printf '  %-46s %s\n' "$1" "$2"; }

echo "Removing DeskStats:"

# Unload before deleting, or launchd keeps a job pointing at a missing binary.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  say "launch agent" "unloaded"
else
  say "launch agent" "not loaded"
fi

pkill -f "DeskStats.app/Contents/MacOS/DeskStats" 2>/dev/null && say "running process" "stopped" \
                                                             || say "running process" "not running"

[ -f "$PLIST" ] && { rm -f "$PLIST"; say "$PLIST" "deleted"; } || say "launch agent plist" "absent"
[ -d "$APP" ]   && { rm -rf "$APP";  say "$APP" "deleted"; }   || say "app bundle" "absent"
[ -f "$CMD" ]   && { rm -f "$CMD";   say "$CMD" "deleted"; }   || say "stats command" "absent"

if defaults read "$LABEL" >/dev/null 2>&1; then
  defaults delete "$LABEL" 2>/dev/null
  say "preferences ($LABEL)" "deleted"
else
  say "preferences" "absent"
fi

echo
echo "Done. This source tree is untouched — ./install.sh reinstalls."
echo "DeskStats requested no system permissions, so there is nothing to revoke."
