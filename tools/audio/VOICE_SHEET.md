# 대사 녹음 안내

마이크로 직접 녹음하면 가장 사실적이고 권리 문제도 없습니다. 같은 문장을 **최대 4번(테이크 0~3)**, 다른 사람이나 다른 분위기로 녹음하면 게임이 번갈아 씁니다.

## 녹음 요령
- 조용한 방, 입에서 한 뼘 정도 거리, WAV 또는 변환 가능한 파일(44.1~48 kHz)
- 문장 앞뒤로 0.5초 정도 비워 두면 도구가 알아서 자릅니다
- 크게 외치되 마이크가 찌그러지지 않게(너무 가까이 대지 않기)
- 파일은 `assets/audio/_voice_raw/`에 아래 이름 그대로 저장하고 `python tools/audio/voice.py process` 실행

## 명령 대사 (경찰)

| 문장 | 분위기 | 파일 이름 (테이크 0~3) |
|---|---|---|
| 무기 버려! | 단호하게, 크게 외침 (경찰이 총을 든 사람에게) | `voice_weapon_drop_0_0.wav` ~ `voice_weapon_drop_0_3.wav` |
| 당장 무기 내려놔! | 단호하게, 크게 외침 (경찰이 총을 든 사람에게) | `voice_weapon_drop_1_0.wav` ~ `voice_weapon_drop_1_3.wav` |
| 경찰이다, 무기 버려! | 단호하게, 크게 외침 (경찰이 총을 든 사람에게) | `voice_weapon_drop_2_0.wav` ~ `voice_weapon_drop_2_3.wav` |
| 총 내려놓고 물러서! | 단호하게, 크게 외침 (경찰이 총을 든 사람에게) | `voice_weapon_drop_3_0.wav` ~ `voice_weapon_drop_3_3.wav` |
| 엎드려! | 크고 급박하게 (바닥에 엎드리라는 명령) | `voice_down_0_0.wav` ~ `voice_down_0_3.wav` |
| 바닥에 엎드려! | 크고 급박하게 (바닥에 엎드리라는 명령) | `voice_down_1_0.wav` ~ `voice_down_1_3.wav` |
| 숙여, 지금 당장! | 크고 급박하게 (바닥에 엎드리라는 명령) | `voice_down_2_0.wav` ~ `voice_down_2_3.wav` |
| 몸 낮춰, 엎드려! | 크고 급박하게 (바닥에 엎드리라는 명령) | `voice_down_3_0.wav` ~ `voice_down_3_3.wav` |
| 움직이지 마! | 낮고 위협적으로, 힘을 줘서 | `voice_freeze_0_0.wav` ~ `voice_freeze_0_3.wav` |
| 꼼짝 마! | 낮고 위협적으로, 힘을 줘서 | `voice_freeze_1_0.wav` ~ `voice_freeze_1_3.wav` |
| 그대로 멈춰! | 낮고 위협적으로, 힘을 줘서 | `voice_freeze_2_0.wav` ~ `voice_freeze_2_3.wav` |
| 한 발짝도 움직이지 마! | 낮고 위협적으로, 힘을 줘서 | `voice_freeze_3_0.wav` ~ `voice_freeze_3_3.wav` |
| 돌아서, 손 머리 위로! | 침착하지만 단호하게 | `voice_turn_0_0.wav` ~ `voice_turn_0_3.wav` |
| 뒤돌아서 무릎 꿇어! | 침착하지만 단호하게 | `voice_turn_1_0.wav` ~ `voice_turn_1_3.wav` |
| 돌아서 손 들어! | 침착하지만 단호하게 | `voice_turn_2_0.wav` ~ `voice_turn_2_3.wav` |
| 천천히 돌아서! | 침착하지만 단호하게 | `voice_turn_3_0.wav` ~ `voice_turn_3_3.wav` |

## 민간인/적 소리

| 소리 | 분위기 | 파일 이름 |
|---|---|---|
| 꺄악! | 민간인이 놀라서 지르는 비명 | `voice_npc_scream_0.wav` ~ `voice_npc_scream_3.wav` |
| (비명, 말 없이) | 놀람과 공포의 긴 비명 | `scream_0.wav` ~ `scream_3.wav` |
| (신음) | 총에 맞았을 때 짧은 신음과 숨 | `hurt_0.wav` ~ `hurt_3.wav` |
