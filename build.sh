#!/bin/zsh
# PortBar.app 을 빌드한다. 사용법: ./build.sh [--install | --zip]
#   --install  빌드 후 /Applications 로 복사하고 실행한다.
#   --zip      GitHub Release에 올릴 build/PortBar.zip 을 만든다.
set -euo pipefail

cd "$(dirname "$0")"
APP=build/PortBar.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  Sources/*.swift -o build/PortBar-arm64
swiftc -O -parse-as-library -swift-version 5 \
  -target x86_64-apple-macosx14.0 \
  Sources/*.swift -o build/PortBar-x86_64
lipo -create build/PortBar-arm64 build/PortBar-x86_64 -output "$APP/Contents/MacOS/PortBar"
rm build/PortBar-arm64 build/PortBar-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PortBar</string>
  <key>CFBundleDisplayName</key><string>PortBar</string>
  <key>CFBundleIdentifier</key><string>local.seungyun.PortBar</string>
  <key>CFBundleExecutable</key><string>PortBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "빌드 완료: $PWD/$APP"

if [[ "${1:-}" == "--zip" ]]; then
  rm -f build/PortBar.zip
  ditto -c -k --keepParent "$APP" build/PortBar.zip
  echo "배포용 압축: $PWD/build/PortBar.zip"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PortBar 2>/dev/null || true
  rm -rf /Applications/PortBar.app
  cp -R "$APP" /Applications/
  open /Applications/PortBar.app
  echo "설치 및 실행: /Applications/PortBar.app"
fi
