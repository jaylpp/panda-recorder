#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/熊猫录屏.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -target arm64-apple-macosx15.0 -swift-version 5 -O -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework AVKit -framework CoreImage Sources/main.swift -o "$APP/Contents/MacOS/MotionRecorder"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.pandajay.rea.motionrecorder</string><key>CFBundleExecutable</key><string>MotionRecorder</string><key>CFBundleName</key><string>熊猫录屏</string><key>CFBundleDisplayName</key><string>熊猫录屏</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>NSHighResolutionCapable</key><true/><key>NSMicrophoneUsageDescription</key><string>录制你的旁白，并与录屏视频一起保存在本机。</string><key>NSScreenCaptureUsageDescription</key><string>录制你选择的窗口并生成本地运镜视频。</string></dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
