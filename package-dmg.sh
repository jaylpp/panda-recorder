#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" != "--skip-build" ]]; then bash build.sh; fi
APP="$PWD/build/熊猫录屏.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DEST="$PWD/build/release"
mkdir -p "$DEST"
STAGE=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
MOUNT="$STAGE/mounted"
cleanup() { hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$STAGE/content"
ditto "$APP" "$STAGE/content/熊猫录屏.app"
ln -s /Applications "$STAGE/content/应用程序"
DMG="$DEST/PandaRecorder-v${VERSION}-macOS-arm64.dmg"
python3 -c 'import PIL, ds_store, mac_alias' || { echo "请先运行：python3 -m pip install Pillow ds-store mac-alias" >&2; exit 1; }
hdiutil create -volname "熊猫录屏" -srcfolder "$STAGE/content" -format UDRW -ov "$STAGE/writable.dmg"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -mountpoint "$MOUNT" "$STAGE/writable.dmg"
python3 scripts/dmg-layout.py "$MOUNT"
hdiutil detach "$MOUNT"
hdiutil convert "$STAGE/writable.dmg" -format UDZO -ov -o "$DMG"
(cd "$DEST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
printf '%s\n' "$DMG"
