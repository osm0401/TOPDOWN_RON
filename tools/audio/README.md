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
| `scream_<n>.wav`, `hurt_<n>.wav` | 비명, 신음 |

## 대사 녹음 (AI가 못 하는 부분)
Stable Audio Open은 사실적인 목소리를 만들지 못합니다(모델 카드). 직접 녹음이 가장 사실적이고 권리 문제도 없습니다.
1. `voice.py sheet` → `tools/audio/VOICE_SHEET.md`에 문장별 파일 이름과 분위기가 나옵니다.
2. 그 이름대로 `assets/audio/_voice_raw/`에 저장
3. `voice.py process` → 앞뒤 무음 제거, 저음 잡음 제거, 테이크 간 음량 맞춤 후 `assets/audio/`에 저장

## 검사
`test_tools.py`: 합성 신호로 선별, 가공, 루프, 녹음 처리, 생성 계획을 확인합니다(GPU, 모델 불필요).

## 라이선스
이 모델은 Stability AI Community License입니다. 공개 저장소에 올리거나 게임을 판매하기 전에
[stability.ai/license](https://stability.ai/license)를 확인하세요. 그때까지 `assets/audio`는 커밋하지 않습니다.
