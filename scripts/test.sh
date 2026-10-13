#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -target arm64-apple-macosx15.0 -swift-version 5 -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework CoreImage Sources/Recording.swift Sources/VideoProcessing.swift Sources/Controls.swift Tests/main.swift -o "$test_dir/tests"
"$test_dir/tests"
