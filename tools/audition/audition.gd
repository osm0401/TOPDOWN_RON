extends Control
## Take-picking tool: listen to every generated take and mark it "use" or "skip".
##   Godot --path D:/TOPDOWNRON res://tools/audition/audition.tscn      (or tools/audio/pick_sounds.bat)
## Decisions are saved at once (assets/audio/_pick); G turns the picks into game files.

const PYTHON := "D:/tools/sao/Scripts/python.exe"
const GOOD := Color(0.45, 0.9, 0.5)
const BAD := Color(1.0, 0.45, 0.4)
const DIM := Color(0.62, 0.64, 0.7)

var _model: AuditionModel
var _player := AudioStreamPlayer.new()
var _k := 0  ## selected sound
var _i := 0  ## selected take of that sound
var _auto := true
var _busy := false
var _keys_list := ItemList.new()
var _takes_list := ItemList.new()
var _head := Label.new()
var _detail := Label.new()
var _badge := Label.new()
var _summary := Label.new()
var _status := Label.new()
var _wave := Wave.new()


## Amplitude outline of the take with a play position line.
class Wave extends Control:
	var peaks := PackedFloat32Array()
	var pos := -1.0  ## 0..1 or -1

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.09, 0.11))
		var n := peaks.size()
		for c in n:
			var x := size.x * float(c) / maxf(n, 1)
			var h := peaks[c] * size.y * 0.48
			draw_line(Vector2(x, size.y * 0.5 - h), Vector2(x, size.y * 0.5 + h), Color(0.45, 0.7, 1.0), maxf(size.x / maxf(n, 1), 1.0))
		if pos >= 0.0:
			draw_line(Vector2(pos * size.x, 0), Vector2(pos * size.x, size.y), Color(1, 0.85, 0.3), 2.0)


func _ready() -> void:
	var audio_root := ProjectSettings.globalize_path("res://assets/audio")
	_model = AuditionModel.new(audio_root)
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tools/audio/catalog.json"))
	_model.load_all(catalog["sounds"].keys() if catalog is Dictionary else [])
	add_child(_player)
	_build_ui()
	if _model.keys.is_empty():
		_status.text = "assets/audio/_raw 에 생성된 소리가 없습니다 (tools/audio/generate.py 먼저)"
		return
	_refresh_keys()
	_select(0, 0)


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.12, 0.15)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)
	var title := Label.new()
	title.text = "소리 고르기: 듣고 '사용' 또는 '제외'를 정하세요 (바로 저장됩니다)"
	title.add_theme_font_size_override("font_size", 20)
	col.add_child(title)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	col.add_child(row)

	_keys_list.custom_minimum_size = Vector2(260, 0)
	_keys_list.focus_mode = Control.FOCUS_NONE
	_keys_list.item_selected.connect(func(i: int) -> void: _select(i, 0))
	row.add_child(_keys_list)

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 10)
	row.add_child(mid)
	_head.add_theme_font_size_override("font_size", 34)
	mid.add_child(_head)
	_detail.add_theme_color_override("font_color", DIM)
	mid.add_child(_detail)
	_wave.custom_minimum_size = Vector2(0, 230)
	_wave.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(_wave)
	_badge.add_theme_font_size_override("font_size", 44)
	mid.add_child(_badge)
	mid.add_child(_summary)

	_takes_list.custom_minimum_size = Vector2(330, 0)
	_takes_list.focus_mode = Control.FOCUS_NONE
	_takes_list.item_selected.connect(func(i: int) -> void: _select(_k, i))
	row.add_child(_takes_list)

	var help := Label.new()
	help.text = "Space 다시 듣기    Y / Enter 사용    N / Delete 제외    U 미정으로    ← → 이전/다음 조각    Tab 다음 소리 (Shift+Tab 이전)    P 자동재생    G 게임용으로 가공    Esc 종료"
	help.add_theme_color_override("font_color", DIM)
	col.add_child(help)
	_status.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	col.add_child(_status)


func _process(_delta: float) -> void:
	if _player.playing and _player.stream != null:
		_wave.pos = _player.get_playback_position() / maxf(_player.stream.get_length(), 0.01)
	else:
		_wave.pos = -1.0
	_wave.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if _busy or not (event is InputEventKey) or not event.pressed or event.echo or _model.keys.is_empty():
		return
	match event.physical_keycode:
		KEY_SPACE:
			_play()
		KEY_Y, KEY_ENTER, KEY_KP_ENTER:
			_decide(AuditionModel.USE)
		KEY_N, KEY_DELETE, KEY_BACKSPACE:
			_decide(AuditionModel.SKIP)
		KEY_U:
			_decide("", false)
		KEY_LEFT:
			_step(-1)
		KEY_RIGHT:
			_step(1)
		KEY_TAB:
			_select(posmod(_k + (-1 if event.shift_pressed else 1), _model.keys.size()), 0)
		KEY_P:
			_auto = not _auto
			_status.text = "자동 재생 " + ("켬" if _auto else "끔")
		KEY_G:
			_run_process()
		KEY_ESCAPE:
			get_tree().quit()
		_:
			return
	get_viewport().set_input_as_handled()


# ---- selection / playback ------------------------------------------------------

func _key() -> String:
	return _model.keys[_k]


func _take() -> Dictionary:
	return _model.takes[_key()][_i]


func _select(k: int, i: int) -> void:
	_k = k
	_i = clampi(i, 0, maxi(_model.takes[_key()].size() - 1, 0))
	_takes_list.clear()
	for t in _model.takes[_key()]:
		_takes_list.add_item("")
	_refresh_takes()
	_keys_list.select(_k)
	_load_take()


func _step(d: int) -> void:
	var n: int = _model.takes[_key()].size()
	if _i + d >= 0 and _i + d < n:
		_i += d
		_takes_list.select(_i)
		_load_take()
	elif d > 0:
		_select(posmod(_k + 1, _model.keys.size()), 0)
		_status.text = "다음 소리: " + _key()
	_refresh_head()


func _load_take() -> void:
	var t := _take()
	var s := AudioStreamWAV.load_from_file(_model.raw_path(_key(), t["file"]))
	_player.stream = s
	_wave.peaks = _peaks(s, 640)
	_takes_list.select(_i)
	_takes_list.ensure_current_is_visible()
	_refresh_head()
	if _auto:
		_play()


func _play() -> void:
	if _player.stream != null:
		_player.play()


func _decide(value: String, advance: bool = true) -> void:
	_model.set_decision(_key(), _take()["file"], value)
	_refresh_takes()
	_refresh_keys()
	_refresh_head()
	if advance:
		_step(1)


## Per-column peak of a 16-bit WAV (every stride-th sample is enough for an outline).
func _peaks(s: AudioStreamWAV, columns: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if s == null or s.format != AudioStreamWAV.FORMAT_16_BITS:
		return out
	var frames := s.data.size() / (4 if s.stereo else 2)
	var step := 2 if s.stereo else 1
	var per := maxi(frames / columns, 1)
	var stride := maxi(per / 48, 1)
	out.resize(columns)
	for c in columns:
		var m := 0
		var f := c * per
		while f < mini((c + 1) * per, frames):
			m = maxi(m, absi(s.data.decode_s16(f * step * 2)))
			f += stride
		out[c] = float(m) / 32768.0
	return out


# ---- display -------------------------------------------------------------------

func _refresh_head() -> void:
	var t := _take()
	var d := _model.decision(_key(), t["file"])
	_head.text = "%s    %d / %d" % [_key(), _i + 1, _model.takes[_key()].size()]
	_detail.text = "%s    점수 %.2f    시작 %s초    소리 덩어리 %s    음색 %s Hz" % [t["file"], t["score"], t["onset_s"], t["events"], t["centroid_hz"]]
	_badge.text = {AuditionModel.USE: "✓ 사용", AuditionModel.SKIP: "✗ 제외", "": "· 미정"}[d]
	_badge.add_theme_color_override("font_color", GOOD if d == AuditionModel.USE else (BAD if d == AuditionModel.SKIP else DIM))
	var c := _model.counts(_key())
	var all := _model.counts()
	_summary.text = "이 소리: 사용 %d · 제외 %d · 미정 %d        전체: 사용 %d · 제외 %d · 미정 %d" % [c["use"], c["skip"], c["open"], all["use"], all["skip"], all["open"]]


func _refresh_takes() -> void:
	for i in _model.takes[_key()].size():
		var t: Dictionary = _model.takes[_key()][i]
		var d := _model.decision(_key(), t["file"])
		var mark: String = {AuditionModel.USE: "✓", AuditionModel.SKIP: "✗", "": "·"}[d]
		_takes_list.set_item_text(i, "%s  %s   %.2f" % [mark, t["file"].get_basename(), t["score"]])
		_takes_list.set_item_custom_fg_color(i, GOOD if d == AuditionModel.USE else (BAD if d == AuditionModel.SKIP else Color.WHITE))


func _refresh_keys() -> void:
	if _keys_list.item_count != _model.keys.size():
		_keys_list.clear()
		for k in _model.keys:
			_keys_list.add_item(k)
	for i in _model.keys.size():
		var c := _model.counts(_model.keys[i])
		_keys_list.set_item_text(i, "%s   ✓%d ✗%d ·%d" % [_model.keys[i], c["use"], c["skip"], c["open"]])
	_keys_list.select(_k)


# ---- game files ----------------------------------------------------------------

## Runs tools/audio/process.py on the picks, then lets Godot import the new files.
func _run_process() -> void:
	if not FileAccess.file_exists(PYTHON):
		_status.text = "파이썬을 찾을 수 없습니다: " + PYTHON
		return
	_busy = true
	_status.text = "게임용으로 가공 중... (잠시 기다려 주세요)"
	await get_tree().process_frame
	await get_tree().process_frame
	var out := []
	var code := OS.execute(PYTHON, [ProjectSettings.globalize_path("res://tools/audio/process.py"), "--replace"], out, true)
	var text := "\n".join(PackedStringArray(out)).strip_edges()
	if code != 0:
		_status.text = "가공 실패(코드 %d): %s" % [code, text.get_slice("\n", text.get_slice_count("\n") - 1)]
		_busy = false
		return
	_status.text = "가공 완료. Godot에 가져오는 중..."
	await get_tree().process_frame
	await get_tree().process_frame
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--import"], [], true)
	_status.text = "끝났습니다. 이제 게임을 실행하면 고른 소리가 쓰입니다.  (%s)" % text.replace("\n", " / ")
	_busy = false
