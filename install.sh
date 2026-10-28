#!/bin/zsh
# GitHub Release의 최신 PortBar.zip 을 받아 /Applications 에 설치하고 실행한다.
#   공개 레포: curl -fsSL https://raw.githubusercontent.com/awwsome/PortBar/main/install.sh | zsh
#   비공개 레포: gh 로그인 후 위와 같은 install.sh 를 실행하면 gh로 내려받는다.
set -euo pipefail

REPO="awwsome/PortBar"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "PortBar 최신 버전을 내려받는 중…"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download --repo "$REPO" --pattern PortBar.zip --dir "$TMP"
else
  curl -fsSL "https://github.com/$REPO/releases/latest/download/PortBar.zip" -o "$TMP/PortBar.zip"
fi

ditto -x -k "$TMP/PortBar.zip" "$TMP"
pkill -x PortBar 2>/dev/null || true
rm -rf /Applications/PortBar.app
ditto "$TMP/PortBar.app" /Applications/PortBar.app
# 서명되지 않은 앱이라 다운로드 격리 표시가 있으면 Gatekeeper가 실행을 막는다.
xattr -dr com.apple.quarantine /Applications/PortBar.app 2>/dev/null || true

open /Applications/PortBar.app
echo "설치 완료: /Applications/PortBar.app (상태 바를 확인하세요)"
