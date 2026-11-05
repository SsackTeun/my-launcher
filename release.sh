#!/bin/zsh
# 새 버전을 GitHub Releases 에 올림 (도구함의 '개발자 앱' 탭이 여기서 받아 감)
#   ./release.sh 1.2
set -e
cd "$(dirname "$0")"
VER=${1:?버전을 적어 주세요. 예: ./release.sh 1.2}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VER" Info.plist
rm -rf dist && mkdir dist
OUT=dist ./build.sh
ditto -c -k --keepParent "dist/도구함.app" dist/Launcher.zip
git add Info.plist
git diff --cached --quiet || git commit -m "버전 $VER"
git tag -f "v$VER"
git push origin HEAD "v$VER" --force
gh release create "v$VER" dist/Launcher.zip --title "도구함 $VER" --notes "도구함의 '개발자 앱' 탭에서 업데이트하거나, 압축을 풀어 Applications 폴더에 넣으세요. (macOS 26 이상)" --latest
echo "올림: v$VER"
