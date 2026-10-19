#!/usr/bin/env bash
# Install or update the topology agent as a per-user LaunchAgent (idempotent).
# Settings come from the environment or from deploy/local.env (gitignored):
#   TSTOPO_LABEL       LaunchAgent label (default local.tstopo)
#   TSTOPO_PVE_GUESTS  comma-separated node names drawn as guests of the pve host
#   TSTOPO_HIDDEN      comma-separated node names left out of the topology
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$DIR/local.env" ] && . "$DIR/local.env"

LABEL="${TSTOPO_LABEL:-local.tstopo}"
SRC="$(dirname "$DIR")"
DEST="$HOME/Library/Application Support/tstopo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/tstopo.log"

mkdir -p "$DEST"
rsync -a --delete --exclude '__pycache__' "$SRC/tstopo" "$DEST/"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>-m</string><string>tstopo.agent</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TSTOPO_PVE_GUESTS</key><string>${TSTOPO_PVE_GUESTS:-}</string>
    <key>TSTOPO_HIDDEN</key><string>${TSTOPO_HIDDEN:-}</string>
  </dict>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL, log: $LOG"
