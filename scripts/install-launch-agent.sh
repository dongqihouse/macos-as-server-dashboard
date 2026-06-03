#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BINARY_PATH="$ROOT_DIR/.build/release/MacServerDashboard"
BINARY_PATH="${1:-"$DEFAULT_BINARY_PATH"}"
LABEL="dev.codex.mac-server-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "$BINARY_PATH" != /* ]]; then
  BINARY_PATH="$ROOT_DIR/$BINARY_PATH"
fi

if [[ -f "$ROOT_DIR/Package.swift" ]]; then
  cd "$ROOT_DIR"
  swift build -c release
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Executable not found: $BINARY_PATH" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/MacServerDashboard"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BINARY_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/MacServerDashboard/app.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/MacServerDashboard/app.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
echo "Config: $HOME/Library/Application Support/MacServerDashboard/config.json"
