# assets/props

3D 화면의 가구·소품 모델 파일 자리입니다. 파일이 없으면 게임이 코드로 만든 모양(`src/game/prop_models.gd`)을 씁니다.

- 어디에 무엇이 있는지는 맵 파일(`data/maps.json`에 목록: 주택 `map_01.json`, 아파트 `map_02_apartment.json`, 주유소 `map_03_gas_station.json`)의 `props`(종류, 사각형, 앞면 방향)에서 정합니다.
- 모델 파일은 묶음 폴더에 넣습니다: `assets/props/<set>/<종류>.glb`. `<set>`은 `data/view3d.json`의 `characters.set`이고, 지금은 `gemini`예요.
- 종류 목록과 규칙(원점, 방향, 크기), 만드는 사람(Antigravity): `docs/09-3d-models-antigravity.md`의 3-1
