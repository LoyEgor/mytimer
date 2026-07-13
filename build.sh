#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
cd "$root"
swift build -c release
mkdir -p MyTimer.app/Contents/MacOS MyTimer.app/Contents/Resources
cp .build/release/MyTimer MyTimer.app/Contents/MacOS/MyTimer
cp Info.plist MyTimer.app/Contents/Info.plist
cp Assets/AppIcon.icns MyTimer.app/Contents/Resources/AppIcon.icns
cp Assets/Assets.car MyTimer.app/Contents/Resources/Assets.car
codesign --force --deep --sign - MyTimer.app
echo "Built $root/MyTimer.app"
