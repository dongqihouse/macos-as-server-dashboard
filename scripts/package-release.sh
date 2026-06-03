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
PACKAGE_DIR="$DIST_DIR/$APP_NAME-$VERSION-macos-$ARCH"
ARCHIVE="$DIST_DIR/$APP_NAME-$VERSION-macos-$ARCH.tar.gz"
CHECKSUMS="$DIST_DIR/$APP_NAME-$VERSION-checksums.txt"

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-"$ROOT_DIR/.build/clang-module-cache"}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build -c release

rm -rf "$PACKAGE_DIR" "$ARCHIVE" "$CHECKSUMS"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/scripts"

cp ".build/release/$APP_NAME" "$PACKAGE_DIR/bin/$APP_NAME"
cp scripts/install-launch-agent.sh "$PACKAGE_DIR/scripts/install-launch-agent.sh"
cp scripts/uninstall-launch-agent.sh "$PACKAGE_DIR/scripts/uninstall-launch-agent.sh"
cp config.sample.json "$PACKAGE_DIR/config.sample.json"
cp README.md "$PACKAGE_DIR/README.md"

cat > "$PACKAGE_DIR/INSTALL.md" <<EOF
# $APP_NAME $VERSION

Run from the extracted package directory:

\`\`\`bash
scripts/install-launch-agent.sh bin/$APP_NAME
\`\`\`

Uninstall:

\`\`\`bash
scripts/uninstall-launch-agent.sh
\`\`\`
EOF

tar -czf "$ARCHIVE" -C "$DIST_DIR" "$(basename "$PACKAGE_DIR")"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUMS")"
)

echo "Created:"
echo "  $ARCHIVE"
echo "  $CHECKSUMS"
