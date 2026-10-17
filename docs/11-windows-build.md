# Windows 실행 파일(.exe) 만들기

친구가 Godot 없이 게임을 할 수 있게, 게임을 exe 하나로 내보내요(게임 데이터가 exe 안에 들어감).

## 한 번만: 내보내기 템플릿 받기
Godot 에디터 → 편집기 → 내보내기 템플릿 관리 → 다운로드 (4.7.2). Windows용만 쓰지만 전체가 한 묶음이에요.

## 만들기
- 에디터: 프로젝트 → 내보내기 → "Windows Desktop" → 프로젝트 내보내기 (Debug 체크 해제)
- 명령줄:
```
Godot_v4.7.2-stable_win64_console.exe --headless --path D:\TOPDOWNRON --export-release "Windows Desktop" build\windows\TOPDOWNRON.exe
```
- 결과: `build/windows/TOPDOWNRON.exe` (약 115MB, 압축하면 약 45MB). `build/`는 git에 올리지 않아요.

## 들어가는 것 / 빠지는 것 (`export_presets.cfg`)
- 들어감: 스크립트, 장면, 모델·텍스처, `data/*.json`
- 빠짐: `tests/`, `tools/`, `docs/`, **`assets/audio/`** — 레오낫 소리 파일은 절대 exe에 들어가지 않아요. exe에서는 합성음이 나와요.

## 친구에게 줄 때
- 둘 다 **같은 exe**를 써야 해요(버전이 다르면 연결이 안 돼요). 게임을 고치면 exe를 다시 만들어 둘 다 바꿔요.
- 처음 실행할 때 "Windows의 PC 보호" 창이 뜨면 "추가 정보" → "실행" (서명 없는 프로그램 경고).
- 친구랑 연결하는 법: `docs/03-radmin-guide.md`
