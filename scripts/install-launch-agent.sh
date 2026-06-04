#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacServerDashboard"
DEFAULT_APP_PATH="/Applications/$APP_NAME.app"
DEFAULT_BINARY_PATH="$ROOT_DIR/.build/release/$APP_NAME"
TARGET_PATH="${1:-}"
LABEL="dev.codex.mac-server-dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ -z "$TARGET_PATH" ]]; then
  if [[ -d "$DEFAULT_APP_PATH" ]]; then
    TARGET_PATH="$DEFAULT_APP_PATH"
  else
    TARGET_PATH="$DEFAULT_BINARY_PATH"
  fi
fi

if [[ "$TARGET_PATH" != /* ]]; then
  TARGET_PATH="$ROOT_DIR/$TARGET_PATH"
fi

if [[ -d "$TARGET_PATH/Contents/MacOS" ]]; then
  BINARY_PATH="$TARGET_PATH/Contents/MacOS/$APP_NAME"
else
  BINARY_PATH="$TARGET_PATH"
fi

if [[ -f "$ROOT_DIR/Package.swift" && "$BINARY_PATH" == "$DEFAULT_BINARY_PATH" ]]; then
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
