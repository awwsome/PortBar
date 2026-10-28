# PortBar

열려 있는 포트를 확인하고 바로 끌 수 있는 macOS 상태 바 앱입니다.

- `node`, `bun`, `vite` 같은 개발 서버만 모아서 **git 레포별로** 묶어 보여 줍니다 (레포 이름, 브랜치, worktree, 하위 폴더).
- ✕ 버튼을 두 번 누르면 종료(SIGTERM)하고, 응답이 없으면 강제 종료(SIGKILL) 버튼으로 바뀝니다.
- 모든 인터페이스에 열린 포트는 `외부 노출`로 표시합니다.
- 레포 메뉴에서 Finder·터미널·에디터·GitHub 열기, 레포의 포트 일괄 종료를 할 수 있습니다.

macOS 14 이상, Apple Silicon과 Intel 모두 지원합니다.

## 설치

### 방법 1. 명령 한 줄 (빌드된 앱 받기)

```bash
curl -fsSL https://raw.githubusercontent.com/awwsome/PortBar/main/install.sh | zsh
```

GitHub Release의 최신 `PortBar.zip`을 받아 `/Applications`에 설치하고 실행합니다.
레포가 비공개라면 `gh auth login`으로 로그인한 뒤, 레포를 클론해서 `./install.sh`를 실행하세요.

### 방법 2. 소스에서 빌드

Xcode 또는 Command Line Tools(`xcode-select --install`)가 필요합니다.

```bash
git clone https://github.com/awwsome/PortBar.git
cd PortBar
./build.sh --install
```

### 브라우저로 zip을 받은 경우

Apple 공증을 받지 않은 앱이라 "손상되었기 때문에 열 수 없습니다"가 뜰 수 있습니다. 아래 명령으로 격리 표시를 지우면 열립니다.

```bash
xattr -dr com.apple.quarantine /Applications/PortBar.app
```

## 새 버전 배포

```bash
./build.sh --zip
gh release create v1.1 build/PortBar.zip --title "v1.1" --notes "변경 내용"
```

## 참고

- 관리자 권한 없이 동작하므로 내 계정으로 실행한 프로세스만 보이고 종료할 수 있습니다.
- 상태 바 아이콘이 안 보이면 Hidden Bar·Bartender 같은 메뉴 막대 정리 앱이 숨긴 것일 수 있습니다. ⌘를 누른 채 아이콘을 끌어 보이는 영역으로 옮기세요.
- 로그인 시 자동 실행은 팝오버 아래 체크박스로 켭니다.
