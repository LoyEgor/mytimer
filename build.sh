#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
cd "$root"
swift build -c release
mkdir -p MyTimer.app/Contents/MacOS
cp .build/release/MyTimer MyTimer.app/Contents/MacOS/MyTimer
cp Info.plist MyTimer.app/Contents/Info.plist
codesign --force --deep --sign - MyTimer.app
echo "Built $root/MyTimer.app"
