#!/bin/zsh
# 도구함.app 빌드 후 ~/Applications 에 설치
set -e
cd "$(dirname "$0")"
A=~/Applications/도구함.app
mkdir -p "$A/Contents/MacOS"
cp Info.plist "$A/Contents/Info.plist"
swiftc -O -swift-version 5 main.swift preview.swift appmenu.swift -o "$A/Contents/MacOS/Launcher" -framework Cocoa -framework ServiceManagement -framework ScreenCaptureKit
codesign -s - --force "$A"
echo "설치 완료: $A"
