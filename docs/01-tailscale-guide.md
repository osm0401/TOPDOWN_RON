# Tailscale 연결 가이드 (사용자 직접 수행)

Claude Code는 계정 생성/로그인/방화벽 변경을 하지 않습니다. 아래는 사용자가 하는 절차입니다.

## 1. 설치 (두 PC 모두)
1. https://tailscale.com/download 에서 Windows용 설치.
2. 같은 계정(또는 초대받은 계정)으로 로그인. 친구 PC는 내 tailnet에 "기기 공유"/초대.
3. 로그인 후 각 PC의 Tailscale IP(`100.x.y.z`) 확인:
```powershell
tailscale ip -4
```

## 2. 연결 확인
호스트 PC IP를 알고 있다면 상대 PC에서:
```powershell
tailscale ping 100.x.y.z
ping 100.x.y.z
```
`tailscale status`에서 상대가 `direct`(직접)면 지연이 낮고, `relay`면 중계 경유라 지연이 큼.

## 3. 게임 포트 (UDP)
- 포트 번호는 `data/net.json`의 값을 사용 (현재 임시값, 확정 전).
- 호스트 PC에서 게임 첫 실행 시 Windows 방화벽 허용 창이 뜨면 **개인 네트워크**에서 허용.
- 시스템/방화벽 설정은 사용자가 직접 변경.

## 4. 한 PC만 있을 때
Tailscale 없이 단계 1 시험 가능: 같은 PC에서 게임 2개 실행, 한쪽이 방 생성, 다른 쪽이 `127.0.0.1` 기반 코드로 참가.
