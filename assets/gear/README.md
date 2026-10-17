# assets/gear

3D 화면의 장비 모델(총, 수갑, 모자, 완장, 문틈 카메라) 파일 자리입니다. 파일이 없으면 게임이 코드로 만든 모양(`src/game/gear_models.gd`)을 씁니다.

- 모델은 묶음 폴더에 넣습니다: `assets/gear/<set>/<종류>.glb` (`<set>`은 `data/view3d.json`의 `characters.set`, 지금 `gemini`)
- 종류: `rifle_lethal`, `rifle_nonlethal`, `pistol`, `camera`, `cuffs`, `cap`, `band`
- 원점, 방향, 크기, 손잡이·총구 같은 점(빈 노드 `grip`, `fore`, `muzzle`, `light`, `stock`, `mag`) 규칙과 검사 방법: `docs/09-3d-models-antigravity.md`
- 만드는 사람: Antigravity(Gemini)
