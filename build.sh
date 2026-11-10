#!/bin/zsh
# 도구함.app 빌드 (애플 실리콘 + 인텔, macOS 26 이상)
#   ./build.sh            → ~/Applications 에 설치
#   OUT=dist ./build.sh   → dist/ 에만 만듦 (배포용)
set -e
cd "$(dirname "$0")"
OUT_DIR=${OUT:-~/Applications}
A="$OUT_DIR/도구함.app"
SRC=(main.swift appmenu.swift ytmusic.swift playerui.swift lyrics.swift pronounce.swift devapps.swift spaces.swift youtube.swift memory.swift onscreen.swift windowpip.swift)
FW=(-framework Cocoa -framework ServiceManagement -framework WebKit -framework SwiftUI -framework Translation -framework NaturalLanguage -framework ScreenCaptureKit -framework CoreMedia)
TMP=$(mktemp -d)
mkdir -p "$A/Contents/MacOS"
cp Info.plist "$A/Contents/Info.plist"
# 커밋 단위 버전: 빌드 번호 = 커밋 수, 커밋 ID, 커밋 안 한 수정이 있었는지, 빌드한 때
PL="$A/Contents/Info.plist"
if git rev-parse --git-dir >/dev/null 2>&1; then
  BN=$(git rev-list --count HEAD)
  GH=$(git rev-parse --short HEAD)
  [ -n "$(git status --porcelain --untracked-files=no)" ] && GD=true || GD=false
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BN" "$PL"
  for k in GitCommit GitDirty BuildDate; do /usr/libexec/PlistBuddy -c "Delete :$k" "$PL" 2>/dev/null || true; done
  /usr/libexec/PlistBuddy -c "Add :GitCommit string $GH" -c "Add :GitDirty bool $GD" -c "Add :BuildDate string $(date '+%Y-%m-%d %H:%M')" "$PL"
fi
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos26.0 $SRC -o "$TMP/Launcher-$arch" $FW
done
lipo -create "$TMP"/Launcher-* -output "$A/Contents/MacOS/Launcher"
rm -rf "$TMP"
# 개발자 인증서가 있으면 그걸로 서명 (다시 빌드해도 macOS 권한이 유지됨), 없으면 임시 서명
ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development|Developer ID/ {print $2; exit}')
codesign -s "${ID:--}" --force "$A"
echo "설치 완료: $A"
