# 도구함 (my-launcher) — 작업 규칙

Mac·Windows 두 컴퓨터에서 번갈아 작업해요. 이 파일은 저장소에 있어서 어느 컴퓨터의 Claude 도 읽어요.

## 시작할 때
- **먼저 `git pull`** — 다른 컴퓨터에서 올린 커밋이 있을 수 있어요. 받기 전에 코드를 보고 판단하지 않기.
- 남은 일은 GitHub 이슈(SsackTeun/my-launcher)에 적혀 있어요. 이어서 할 땐 열린 이슈부터 확인.

## Mac · Windows 맞추기 (제일 중요)
- 코드가 두 벌이에요: **Mac** = 저장소 맨 위 `*.swift` (`./build.sh` → ~/Applications/도구함.app), **Windows** = `windows/` (Tauri v2, `windows/src/music.js` · `style.css` · `src-tauri/`).
- **기능 · 화면을 바꾸면 Mac 과 Windows 를 같은 커밋(또는 바로 다음 커밋)에서 둘 다 고치기.**
  지금 컴퓨터에서 한쪽을 빌드 · 확인할 수 없으면 코드는 고치되, 커밋 메시지에 "(Windows 는 빌드 확인 전)" 처럼 적기.
- 한쪽만 고칠 수밖에 없으면 이슈에 "Mac 에도 할 것: …" 처럼 남기기.
- 사용자가 "윈도우처럼 / 맥처럼" 이라고 하면, 먼저 `git pull` 후 상대편 코드를 읽고 맞추기 (기억으로 판단 금지).

## 빌드 · 릴리스
- Mac: `./build.sh` (설치까지). 릴리스 태그 `v1.x` (자산 Launcher.zip).
- Windows: 태그 `win-v0.x.y` 를 푸시하면 GitHub Actions 가 설치 파일을 만들어요. 버전은 `windows/package.json` · `src-tauri/Cargo.toml` · `Cargo.lock` · `tauri.conf.json` 네 곳을 같이 올리기.
- 커밋 · 푸시 · 릴리스는 사용자가 말할 때만.

## 사용자 관련
- **한국어로**, 쉽게 (어려운 설명엔 짧은 비유 하나).
- **게임 중엔 도구함 다시 켜지 않기**: 다시 켜기 전에 `pgrep -if "maplestory|LeagueOfLegends"` (Windows 면 작업 관리자 기준) 확인. 켜져 있으면 빌드만 하고 "게임 끝나면 다시 켤게요".
- 모호한 화면 요청(스크린샷 + 짧은 말)은 이해한 모양을 한 줄로 확인하고 만들기.
- 테스트할 땐 사용자 플레이리스트를 건드리지 말고 테스트 목록(PLCrPVqv8108A)만.
- 커밋하지 않는 파일: `ytm-*.txt`, `audio-start.txt`, `drag-debug.txt` (진단 기록).
