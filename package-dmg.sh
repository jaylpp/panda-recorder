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
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/熊猫录屏.app"
ln -s /Applications "$STAGE/应用程序"
cat > "$STAGE/安装说明.txt" <<'TXT'
将「熊猫录屏」拖入「应用程序」，然后从应用程序打开。
首次使用点击「授权录屏」，在系统设置中允许录屏，再按系统提示重新打开。
本预览版尚未经过 Apple 公证。使用说明：https://github.com/jaylpp/panda-recorder
TXT
DMG="$DEST/PandaRecorder-v${VERSION}-macOS-arm64.dmg"
hdiutil create -volname "熊猫录屏" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
(cd "$DEST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
printf '%s\n' "$DMG"
