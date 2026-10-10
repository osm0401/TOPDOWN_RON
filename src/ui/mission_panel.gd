class_name MissionPanel
extends Control
## Briefing (floor plan + the two suspect clues), live objective list and the result screen.
## Presentation only: it reads NetWorld.mission and the score rules.

const BG := Color(0.04, 0.05, 0.07, 0.95)
const TEXT := Color(0.92, 0.92, 0.95)
const DIM := Color(0.65, 0.68, 0.75)
const GOOD := Color(0.4, 0.9, 0.5)
const BAD := Color(1.0, 0.4, 0.35)

var world: NetWorld

var _data: Dictionary = {}
var _font: Font = ThemeDB.fallback_font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_data = JsonData.load_dict("res://data/mission.json")


func _process(_delta: float) -> void:
	size = get_viewport_rect().size  # parent is a CanvasLayer: anchors do not apply
	queue_redraw()


func _draw() -> void:
	match world.mission.phase:
		MissionState.Phase.BRIEFING:
			_draw_briefing()
		MissionState.Phase.RESULT:
			_draw_result()
		_:
			_draw_objectives()


# ---- helpers ----------------------------------------------------------------

func _text(at: Vector2, s: String, font_size: int, color: Color = TEXT) -> void:
	draw_string(_font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## Wrapped paragraph; returns the height it used.
func _wrap(at: Vector2, s: String, width: float, font_size: int, color: Color = TEXT) -> float:
	draw_multiline_string(_font, at, s, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, -1, color)
	return _font.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, width, font_size).y


func _draw_clue_icon(at: Vector2, clue: String) -> void:
	draw_circle(at, 13.0, Color(0.8, 0.15, 0.15))
	if clue == "cap":
		draw_arc(at, 10.0, PI, TAU, 10, Color(1.0, 0.15, 0.15), 5.0)
	elif clue == "band":
		draw_line(at + Vector2(15, -7), at + Vector2(15, 7), Color(1.0, 0.9, 0.2), 4.0)


# ---- briefing ---------------------------------------------------------------

func _draw_briefing() -> void:
	var panel := Rect2(size * 0.03, size * 0.94)
	draw_rect(panel, BG)
	draw_rect(panel, Color(0.45, 0.55, 0.8), false, 2.0)
	var x := panel.position.x + 24.0
	var width := panel.size.x * 0.46
	var y := panel.position.y + 42.0
	_text(Vector2(x, y), str(_data["title"]), 26)
	y += 14.0
	y += _wrap(Vector2(x, y + 18.0), str(_data["intro"]), width, 16, DIM) + 30.0
	_text(Vector2(x, y), tr("용의자 식별 단서"), 18, Color(1.0, 0.85, 0.4))
	y += 12.0
	for clue in _data["clues"]:
		_draw_clue_icon(Vector2(x + 14.0, y + 20.0), str(clue["id"]))
		_text(Vector2(x + 42.0, y + 26.0), str(clue["text"]), 17)
		y += 36.0
	y += _wrap(Vector2(x, y + 18.0), str(_data["clue_note"]), width, 15, Color(1.0, 0.85, 0.4)) + 26.0
	_text(Vector2(x, y), tr("필수 목표"), 18, Color(0.6, 0.85, 1.0))
	y += 8.0
	for o in _data["objectives"]:
		y += _wrap(Vector2(x + 8.0, y + 20.0), "- " + str(o), width - 8.0, 15) + 6.0
	y += 14.0
	for r in _data["rules"]:
		y += _wrap(Vector2(x + 8.0, y + 18.0), "* " + str(r), width - 8.0, 14, DIM) + 4.0
	_draw_plan(Rect2(panel.position.x + panel.size.x * 0.52, panel.position.y + 52.0,
			panel.size.x * 0.44, panel.size.y - 150.0))
	var me := world.my_slot
	var mine := world.mission.ready[me]
	var other := world.mission.ready[1 - me]
	var msg := tr("Enter: 준비 완료") if not mine else tr("준비 완료 - 상대를 기다리는 중")
	_text(Vector2(x, panel.end.y - 30.0), msg, 20, GOOD if mine else TEXT)
	var status := tr("싱글 플레이") if world.solo else tr("나: %s    상대: %s") % [tr("준비") if mine else tr("대기"), tr("준비") if other else tr("대기")]
	_text(Vector2(panel.position.x + panel.size.x * 0.52, panel.end.y - 30.0), status, 17, DIM)


func _draw_plan(area: Rect2) -> void:
	var lv := world.level
	_text(area.position + Vector2(0, -8), tr("건물 평면도"), 16, DIM)
	draw_rect(area, Color(0.08, 0.09, 0.11))
	var s := minf(area.size.x / lv.bounds.size.x, area.size.y / lv.bounds.size.y)
	var o := area.position + (area.size - lv.bounds.size * s) * 0.5
	draw_rect(Rect2(o, lv.bounds.size * s), Color(0.11, 0.11, 0.13))
	draw_rect(Rect2(o + lv.building.position * s, lv.building.size * s), Color(0.2, 0.2, 0.22))
	draw_rect(Rect2(o + lv.exit_zone.position * s, lv.exit_zone.size * s), Color(0.15, 0.55, 0.3, 0.7))
	_text(o + lv.exit_zone.position * s + Vector2(6, 22), tr("탈출"), 15, Color(0.7, 1.0, 0.75))
	for rm in lv.rooms:
		var rc := (rm["rect"] as Rect2).get_center() * s + o
		_text(rc + Vector2(-8, 6), str(rm["name"]), 17, Color(0.8, 0.8, 0.85, 0.8))
	for w in lv.wall_rects:
		draw_rect(Rect2(o + w.position * s, w.size * s), Color(0.55, 0.55, 0.6))
	for i in lv.door_rects.size():
		var d := lv.door_rects[i]
		draw_rect(Rect2(o + d.position * s, d.size * s).grow(1.0), Color(0.8, 0.6, 0.3))
		if lv.is_locked(i):
			draw_circle(o + d.get_center() * s, 3.5, Color(0.95, 0.2, 0.2))
	_text(area.position + Vector2(0, area.size.y + 20), tr("갈색=문   빨간 점=잠긴 문   초록=탈출 구역"), 13, DIM)


# ---- live objectives --------------------------------------------------------

func _draw_objectives() -> void:
	var x := size.x - 470.0
	var y := size.y - 120.0
	draw_rect(Rect2(x - 12.0, y - 24.0, 466.0, 24.0 + 24.0 * 4 + 12.0), Color(0, 0, 0, 0.45))
	_text(Vector2(x, y - 6.0), tr("목표"), 15, DIM)
	var names: Array = _data["objectives"]
	for i in names.size():
		var done := world.mission.objectives[i]
		_text(Vector2(x, y + 18.0 + 24.0 * i), ("[완료] " if done else "[    ] ") + str(names[i]), 14, GOOD if done else TEXT)


# ---- result -----------------------------------------------------------------

func _draw_result() -> void:
	var m := world.mission
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.72))
	var panel := Rect2(size * Vector2(0.18, 0.08), size * Vector2(0.64, 0.84))
	draw_rect(panel, BG)
	var ok := m.status == MissionState.Status.SUCCESS
	draw_rect(panel, GOOD if ok else BAD, false, 3.0)
	var x := panel.position.x + 32.0
	var y := panel.position.y + 56.0
	_text(Vector2(x, y), tr("임무 성공") if ok else tr("임무 실패"), 40, GOOD if ok else BAD)
	y += 18.0
	var why := tr("모든 필수 목표를 마치고 탈출 구역으로 귀환했다") if ok else str(_data["fail_reasons"].get(m.reason_key(), ""))
	y += _wrap(Vector2(x, y + 22.0), why, panel.size.x - 64.0, 18, DIM) + 30.0
	var names: Array = _data["objectives"]
	for i in names.size():
		var done := m.objectives[i]
		_text(Vector2(x, y + 20.0), ("[완료] " if done else "[미완료] ") + str(names[i]), 16, GOOD if done else DIM)
		y += 26.0
	y += 20.0
	var c := world.score_counts()
	var score := ScoreRules.compute(c, world.score_rules)
	var grade := ScoreRules.grade(score, world.score_rules)
	_text(Vector2(x, y + 30.0), tr("점수 %d") % score, 30)
	_text(Vector2(x + 220.0, y + 34.0), tr("등급"), 18, DIM)
	_text(Vector2(x + 290.0, y + 40.0), grade, 54, Color(1.0, 0.85, 0.4))
	y += 62.0
	for line in ScoreRules.breakdown(c, world.score_rules):
		_text(Vector2(x + 8.0, y + 20.0), line, 15, DIM)
		y += 22.0
	if ScoreRules.breakdown(c, world.score_rules).is_empty():
		_text(Vector2(x + 8.0, y + 20.0), tr("감점 사항 없음"), 15, DIM)
		y += 22.0
	y += 18.0
	for s in 2:
		if not world.players[s].present:
			continue
		var alive := not world.players[s].dead()
		_text(Vector2(x, y + 20.0), tr("경찰관 %d: %s") % [s + 1, tr("생존") if alive else tr("사망")], 16, GOOD if alive else BAD)
		y += 24.0
	_text(Vector2(x, panel.end.y - 54.0), tr("점수 규칙은 임시값입니다 (시작 점수, 감점, A~F 경계 미확정)"), 13, DIM)
	_text(Vector2(x, panel.end.y - 26.0), tr("Esc: 로비로 돌아가기 (재시도 투표는 다음 단계)"), 15, TEXT)
