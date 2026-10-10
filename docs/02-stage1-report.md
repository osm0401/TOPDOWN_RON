# 단계 1 결과 — 온라인 연결 시험

## 실행
```powershell
# 단위 테스트 (방 코드)
D:\Godot\Godot_v4.7.2-stable_win64_console.exe --headless --path D:\TOPDOWNRON --script tests/run_tests.gd

# 한 PC에서 두 프로세스 자동 연결 시험 (localhost)
powershell -File D:\TOPDOWNRON\tests\net_smoke.ps1 -Runs 5

# 직접 플레이: 게임 창 2개 실행 -> 한쪽 "방 만들기" -> 표시된 코드를 다른 쪽에 입력
D:\Godot\Godot_v4.7.2-stable_win64.exe --path D:\TOPDOWNRON
```
조작: WASD 이동, 마우스 조준, E 문(근처에서만), F 점수 +10(샘플), Esc 나가기.

## 구현 범위
- 방 생성/방 코드 표시/코드 참가 (최대 2명, 3번째 접속 거부)
- 두 플레이어 위치·방향 동기화 (호스트 권한, 클라는 입력만 전송)
- 문 1개 (거리 검증 후 호스트가 토글), 적 상태 샘플(대기/경계), 팀 점수 샘플
- 지연(RTT)·연결·끊김 로그: `user://net_log_host.txt`, `user://net_log_client.txt`
- 끊김 시 알림 후 로비 복귀

## 검증 결과 (이 PC, localhost, 헤드리스)
- 방 코드 단위 테스트 20개 통과
- `net_smoke.ps1` 5회 연속: 호스트/클라 최종 상태 일치 5/5 (문 열림, 적 경계, 점수 20)
- 3번째 클라이언트: 5초 후 접속 실패, 호스트 상태 영향 없음
- RTT 약 7ms (localhost라 의미 없음), 초당 스냅샷 20개

## 미검증
- Tailscale을 통한 실제 두 PC 연결 (두 번째 PC 필요)
- GUI 로비/HUD의 한글 표시와 조작감 (창 모드는 오류 없이 시작만 확인)
- 호스트 쪽 끊김 알림 화면 (로직은 있으나 자동 테스트 없음)
- 클라이언트 이동은 예측 없이 호스트 결과만 표시: 지연이 큰 경로에서의 조작감
- 10회 연속 임무 시작/종료 (임무 흐름 자체가 아직 없음, 단계 5~6)

## 관찰
- 클라 이동 결과가 실행마다 약간 다름 (예: x=540.0 / 543.7). 호스트가 클라 입력 도착 시점까지 적분하기 때문이며 두 화면은 일치.
