#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/package-release.sh v0.1.0" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacServerDashboard"
ARCH="$(uname -m)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/$APP_NAME-$VERSION-stage"
DMG_ROOT="$DIST_DIR/$APP_NAME-$VERSION-dmg-root"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION-macos-$ARCH.dmg"
CHECKSUMS="$DIST_DIR/$APP_NAME-$VERSION-checksums.txt"

cd "$ROOT_DIR"
SOURCE_VERSION="$(sed -nE 's/.*static let current = "([^"]+)".*/\1/p' Sources/MacServerDashboard/AppVersion.swift)"
if [[ -z "$SOURCE_VERSION" ]]; then
  echo "Could not read AppVersion.current." >&2
  exit 1
fi

if [[ "$VERSION" != "v$SOURCE_VERSION" ]]; then
  echo "Release version $VERSION does not match AppVersion.current ($SOURCE_VERSION)." >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-"$ROOT_DIR/.build/clang-module-cache"}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build -c release

rm -rf "$STAGING_DIR" "$DMG_ROOT" "$DMG" "$CHECKSUMS"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>dev.codex.mac-server-dashboard</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SOURCE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$SOURCE_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DMG_ROOT"
cp -R "$APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUMS")"
)

echo "Created:"
echo "  $DMG"
echo "  $CHECKSUMS"
