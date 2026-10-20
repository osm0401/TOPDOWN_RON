# assets/anim

모션 캡처 동작 파일 자리예요. 파일이 없으면 게임은 지금처럼 코드로 만든 동작을 써요.

| 파일 이름 | 언제 쓰나 |
|---|---|
| `walk.glb` / `walk.fbx` | 걷기 (보폭에 맞춰 재생, 뒤로 걸으면 거꾸로) |
| `run.glb` | 달리기 (걷기와 속도에 따라 섞음) |
| `idle.glb` | 가만히 서 있을 때 |
| `hands_up.glb` | 항복할 때 (한 번 재생하고 마지막 자세로 멈춤) |
| `reload.glb` | 재장전할 때 왼팔 |

- 인물마다 다르게 하려면 `walk_officer.glb`, `walk_civilian.glb`처럼 뒤에 이름을 붙여요.
- 확장자는 `.glb`, `.gltf`, `.fbx` 아무거나 돼요. 파일 안의 몸 모양은 쓰지 않고 뼈 움직임만 써요.
- 설정: `data/view3d.json` `characters.clips`. 받는 방법: `docs/15-mocap-and-police-kit.md`
