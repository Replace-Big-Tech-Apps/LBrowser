#!/bin/zsh
# Packages the existing app with a drag-to-Applications install shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/LBrowser.app
[[ -d "$APP" ]] || { echo "Run ./build.sh first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/lbrowser-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/LBrowser.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install.txt" <<'TXT'
LBrowser — macOS 15 or later

Drag LBrowser.app onto Applications, then eject this disk image.

This release is ad-hoc signed and is not notarized by Apple. macOS may
block the first launch. If you trust this download, attempt to open the
app, then use System Settings > Privacy & Security > Open Anyway.
TXT
OUTPUT="build/LBrowser-${VERSION}.dmg"
hdiutil create -volname LBrowser -srcfolder "$STAGING" -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
(cd build && shasum -a 256 "${OUTPUT:t}" > "${OUTPUT:t}.sha256")
echo "Created $OUTPUT"
