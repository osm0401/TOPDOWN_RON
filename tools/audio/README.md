# tools/audio — 소리 제작 도구

AI 효과음 생성, 자동 선별, 게임용 가공, 대사 녹음 처리를 한 흐름으로 묶은 도구입니다.
모든 명령은 생성 환경의 파이썬으로 저장소 루트(`D:\TOPDOWNRON`)에서 실행합니다:
`D:\tools\sao\Scripts\python tools\audio\<도구>.py`

생성된 소리는 `assets/audio/`에 쌓이고 **git에는 올라가지 않습니다**(라이선스 확인 전, `.gitignore` 참고).
파일이 없으면 게임은 코드로 합성한 소리를 씁니다.

## 흐름

| 단계 | 명령 | 결과 |
|---|---|---|
| 0. 계획 확인 | `generate.py --dry-run` | 소리별 생성 개수와 예상 시간 |
| 1. 프롬프트 점검 | `generate.py --probe` | 소리마다 2개씩(약 10분). 들어 보고 `catalog.json`의 프롬프트를 고침 |
| 2. 본 생성 | `generate.py` (또는 `--only rifle,pistol`) | `assets/audio/_raw/<소리>/`에 여러 개(전체 약 70분) |
| 3. 자동 선별 | `rank.py` | 점수 순으로 `_shortlist/<소리>/`에 상위만 복사 |
| 4. 직접 고르기 | 귀로 듣고 마음에 드는 파일을 `_pick/<소리>/`로 복사 | (건너뛰려면 `--from-shortlist`) |
| 5. 게임용 가공 | `process.py --replace` | `assets/audio/<소리>_<번호>.wav` + `manifest.json` |
| 6. 게임에서 확인 | 게임 실행 후 **F7** 소리 시험 | 거리·벽 뒤·방 크기별로 들어 봄 |

- 이어 하기: `generate.py`는 이미 있는 시드를 건너뛰므로 중간에 멈춰도 다시 실행하면 됩니다.
- 속도: 한 개 만드는 데 소리 길이와 상관없이 약 26~28초(RTX 3060, 100단계). 한 번에 4개씩 만들면 12 GB 메모리가 넘쳐 시스템 메모리로 밀려 3배 느려지므로 기본은 2개씩(`catalog.json`의 `batch`)이고 묶음마다 GPU 메모리를 비웁니다. 전체 156개는 약 75분.
- 온도: 배치마다 GPU 온도를 확인해 80도를 넘으면 쉽니다(`--max-temp`), 배치 사이 쉬는 시간은 `--rest`. **CPU 온도는 읽지 못하므로** 쿨링은 직접 확인하세요.
- 재현: `_raw/<소리>/manifest.jsonl`에 시드, 프롬프트, 모델이 기록되고 `manifest.json`이 게임 파일과 원본을 연결합니다.

## Ready or Not 소리 가져오기 (`import_ron.bat`)
FModel / Fmod_Bank_Tools로 꺼낸 Ready or Not 폴더에서 경찰 대사와 무기 소리를 골라 게임에 넣습니다.
`tools/audio/import_ron.bat`을 두 번 누르면 됩니다(옵션은 뒤에 붙임: `import_ron.bat --dry-run`).

| 단계 | 하는 일 |
|---|---|
| 1. 준비 | 처음 한 번 `D:\tools\ron_asr`에 음성 인식(faster-whisper) 환경을 만듦. 생성 환경(`D:\tools\sao`)은 건드리지 않음 |
| 2. 대사 | `import_ron.json`의 `voice_dir`(SWATEli)를 전부 듣고(음성 인식) 대사 표 17줄과 같은 뜻의 대사(Drop the weapon! 등)를 찾음. 표 번호(N)와 맞는 번호 묶음, 파일 이름도 같이 봄 |
| 3. 배정 | 명령 문장마다 테이크 4개 `voice_<명령>_<문장>_<0~3>.wav`. 표 17줄은 모두 어딘가에 들어감(`commands`에서 바꿈). 무전기 음성, 찌그러진 것, 무음, 잡음은 뺌 |
| 4. 무기 | `weapons_dir`(Weapons[0]) 파일 이름으로 총 종류와 소리 층(가까이 / 멀리 / 잔향 / 기계음 / 재장전…)을 나누고 catalog 기준으로 점수. 한 총의 테이크끼리 묶어서 고름(연사할 때 총이 바뀌지 않게) |
| 5. 채우기 | 멀리 들리는 소리가 없으면 가까운 소리를 가공(`make_far.py`), 통째 재장전이 없으면 탄창 빼기 / 넣기 / 노리쇠를 이어 붙임. 신음(`hurt`)도 찾으면 넣음 |
| 6. 검사 | 쓴 파일을 전부 다시 검사(비어 있음, 무음, 길이, 찌그러짐, 직류 성분, 대사는 다듬은 뒤에도 같은 말로 들리는지). 걸리면 다음 후보로 바꿈. 마지막에 `assets/audio` 전체를 검사해 망가진 파일은 치움 |
| 7. 마무리 | Godot 가져오기(`--import`), 보고서 `assets/audio/_import/REPORT.md` |

- 바뀌기 전 파일은 `assets/audio/_backup/<시간>/`에 남습니다. 되돌리려면 그 파일을 `assets/audio/`로 다시 복사하세요.
- 고른 총소리는 소리 고르기 프로그램에 `ron_…`으로 나오고 지금 쓰는 것은 '사용'으로 표시됩니다. 귀로 바꾸고 **G**.
- `import_ron.bat verify` (또는 `verify --fix`): 지금 있는 게임 소리 파일 전체 검사(망가진 것을 백업으로 옮김).
- 음성 인식 없이(`--no-asr`)도 되지만 그때는 표 번호 묶음과 파일 이름으로만 찾습니다. 처음 음성 인식은 파일 수백 개에 몇 분(CPU), 결과는 저장돼 다음부터 빠릅니다.
- 결과가 이상하면 `assets/audio/_import/inventory.csv`(파일마다 들린 문장, 분류, 쓰인 곳)를 보면 원인을 찾을 수 있습니다.
- 검사: `test_import_ron.py` (가짜 폴더로 전체 흐름 확인, 음성 인식·GPU 불필요).
- **권리**: 가져온 소리는 VOID Interactive의 저작물입니다. 개인 시험용으로만 쓰고 공개 저장소에 올리거나 게임과 함께 배포하지 마세요(`assets/audio`는 커밋되지 않음).

## 소리 고르기 프로그램 (듣고 사용/제외)
`tools/audio/pick_sounds.bat`을 두 번 눌러 실행합니다(Godot으로 만든 `tools/audition`).
왼쪽에서 소리를 고르고 한 조각씩 들으며 정합니다. 선택은 바로 저장되고 `assets/audio/_pick/`에 복사됩니다.

| 키 | 동작 |
|---|---|
| Space | 다시 듣기 |
| Y / Enter | 사용으로 표시하고 다음으로 |
| N / Delete | 제외로 표시하고 다음으로 |
| U | 미정으로 되돌리기 |
| ← → | 이전/다음 조각(표시 안 바꿈) |
| Tab / Shift+Tab | 다음/이전 소리 종류 |
| P | 자동 재생 켜기/끄기 |
| G | 고른 것을 게임용으로 가공(`process.py --replace`)하고 Godot에 가져오기 |

- 점수 높은 것부터 나옵니다. 파형과 재생 위치가 보입니다.
- G는 **사용으로 고른 조각이 있는 소리만** 바꿉니다(고른 게 없는 소리는 그대로).
- 나중에 다시 열어도 이전 선택이 남아 있습니다.

## 선별 기준 (`rank.py`)
`catalog.json`의 `kinds`가 소리 종류별 기준입니다: 시작이 빠른지(`onset_s`), 앞쪽에 에너지가 몰려 있는지, 소리 덩어리 수(`events`: 단발이어야 하는 총성이 2번 나는 것 등), 음색 중심(`centroid_hz`), 찌그러짐.
점수는 명백한 실패를 거르는 용도입니다. 최종 선택은 귀로 합니다.

## 게임이 쓰는 파일 이름
| 파일 | 설명 |
|---|---|
| `<소리>_<0~15>.wav` | 같은 이름의 합성음을 대체. 여러 개면 번갈아 재생(같은 것이 연달아 나오지 않음) |
| `<소리>_far_<n>.wav` | 멀리서 작게 들릴 때 쓰는 별도 세트 (`rifle_far`, `pistol_far`) |
| `hum_<n>.wav` | 방 안 낮은 소음(반복 재생). 가공 시 이음매 없이 이어 붙임 |
| `voice_<명령>_<줄>_<테이크>.wav` | 녹음한 대사. 화면에 뜨는 문장과 일치하는 파일이 재생됨 |
| `voice_npc_scream_<테이크>.wav` | 민간인 "꺄악!" |
| `scream_<n>.wav`, `hurt_<n>.wav` | 비명, 신음 (`hurt`는 Ready or Not 가져오기가 내 경찰의 신음으로 채울 수 있음) |

## 대사 녹음 (AI가 못 하는 부분)
Stable Audio Open은 사실적인 목소리를 만들지 못합니다(모델 카드). 직접 녹음이 가장 사실적이고 권리 문제도 없습니다.
1. `voice.py sheet` → `tools/audio/VOICE_SHEET.md`에 문장별 파일 이름과 분위기가 나옵니다.
2. 그 이름대로 `assets/audio/_voice_raw/`에 저장
3. `voice.py process` → 앞뒤 무음 제거, 저음 잡음 제거, 테이크 간 음량 맞춤 후 `assets/audio/`에 저장

## 검사
`test_tools.py`: 합성 신호로 선별, 가공, 루프, 녹음 처리, 생성 계획을 확인합니다(GPU, 모델 불필요).
`test_import_ron.py`: 가짜 Ready or Not 폴더로 대사 찾기·배정, 무기 분류·선택, 검사와 교체, 백업, 미리보기를 확인합니다.

## 라이선스
이 모델은 Stability AI Community License입니다. 공개 저장소에 올리거나 게임을 판매하기 전에
[stability.ai/license](https://stability.ai/license)를 확인하세요. 그때까지 `assets/audio`는 커밋하지 않습니다.
