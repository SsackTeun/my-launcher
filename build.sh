#!/bin/zsh
# 도구함.app 빌드 후 ~/Applications 에 설치
set -e
cd "$(dirname "$0")"
A=~/Applications/도구함.app
mkdir -p "$A/Contents/MacOS"
cp Info.plist "$A/Contents/Info.plist"
swiftc -O -swift-version 5 main.swift preview.swift appmenu.swift ytmusic.swift playerui.swift -o "$A/Contents/MacOS/Launcher" -framework Cocoa -framework ServiceManagement -framework ScreenCaptureKit -framework WebKit
# 개발자 인증서가 있으면 그걸로 서명 (다시 빌드해도 macOS 권한이 유지됨), 없으면 임시 서명
ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development|Developer ID/ {print $2; exit}')
codesign -s "${ID:--}" --force "$A"
echo "설치 완료: $A"
