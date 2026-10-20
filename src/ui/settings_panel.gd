class_name SettingsPanel
extends PanelContainer
## Settings: sound volumes, graphics, mouse sensitivity and key bindings (GameSettings).
## Every change applies at once; the file is saved when the panel closes. Used from the lobby
## and from the in-mission pause menu.

signal closed

const QUALITY_KEYS: Array[String] = ["high", "medium", "low"]
const QUALITY_NAMES: Array[String] = ["높음", "보통", "낮음"]
const FPS_CAPS: Array[int] = [0, 30, 60, 120, 144, 240]

var _key_buttons: Dictionary = {}  ## action -> Button
var _waiting := ""  ## action whose new key is being waited for
var _note: Label
var _refreshers: Array[Callable] = []  ## put each control back to the stored value (after a reset)


func _ready() -> void:
	custom_minimum_size = Vector2(640, 500)
	theme = _theme()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.11, 0.97)
	sb.border_color = Color(0.35, 0.4, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var title := Label.new()
	title.text = tr("설정")
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.focus_mode = Control.FOCUS_NONE
	box.add_child(tabs)
	tabs.add_child(_sound_tab())
	tabs.add_child(_graphics_tab())
	tabs.add_child(_controls_tab())
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	box.add_child(_note)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	buttons.add_child(_button(tr("모두 기본값으로"), _reset_all))
	buttons.add_child(_button(tr("닫기"), close))


func close() -> void:
	_waiting = ""
	GameSettings.save_file()
	closed.emit()


# ---- tabs -------------------------------------------------------------------------

func _sound_tab() -> Control:
	var g := _grid(tr("소리"))
	_slider(g, tr("전체 음량"), "audio", "master", 0.0, 1.0, 0.05, true)
	_slider(g, tr("효과음"), "audio", "sfx", 0.0, 1.0, 0.05, true)
	_slider(g, tr("배경음 (긴장감 음악)"), "audio", "music", 0.0, 1.0, 0.05, true)
	return g.get_parent()


func _graphics_tab() -> Control:
	var g := _grid(tr("그래픽"))
	_label(g, tr("그래픽 품질"))
	var q := OptionButton.new()
	q.focus_mode = Control.FOCUS_NONE
	for i in QUALITY_KEYS.size():
		q.add_item(tr(QUALITY_NAMES[i]))
	var show_q := func() -> void:
		var cur := str(GameSettings.value("graphics", "quality"))
		if cur == "":
			cur = WorldView3D.quality if WorldView3D.quality != "" else "high"
		q.select(maxi(QUALITY_KEYS.find(cur), 0))
	show_q.call()
	_refreshers.append(show_q)
	q.item_selected.connect(func(i: int) -> void: _change("graphics", "quality", QUALITY_KEYS[i]))
	g.add_child(q)
	_check(g, tr("전체 화면"), "graphics", "fullscreen")
	_check(g, tr("수직 동기화 (화면 찢김 방지)"), "graphics", "vsync")
	_label(g, tr("최대 FPS"))
	var fps := OptionButton.new()
	fps.focus_mode = Control.FOCUS_NONE
	for cap in FPS_CAPS:
		fps.add_item(tr("제한 없음") if cap == 0 else str(cap))
	var show_fps := func() -> void: fps.select(maxi(FPS_CAPS.find(int(GameSettings.value("graphics", "max_fps"))), 0))
	show_fps.call()
	_refreshers.append(show_fps)
	fps.item_selected.connect(func(i: int) -> void: _change("graphics", "max_fps", FPS_CAPS[i]))
	g.add_child(fps)
	_slider(g, tr("3D 해상도 (낮추면 빨라짐)"), "graphics", "render_scale", 0.5, 1.0, 0.05, true)
	_slider(g, tr("화면 흔들림"), "graphics", "shake", 0.0, 2.0, 0.1, true)
	return g.get_parent()


func _controls_tab() -> Control:
	var g := _grid(tr("조작"))
	_slider(g, tr("마우스 감도"), "controls", "sensitivity", 0.2, 3.0, 0.05, false)
	var hint := Label.new()
	hint.text = tr("감도 1.0은 윈도우 커서 그대로. 다른 값이면 임무 중 조준점이 그만큼 빠르거나 느리게 움직인다.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.65, 0.68, 0.75))
	hint.add_theme_font_size_override("font_size", 13)
	hint.custom_minimum_size = Vector2(240, 0)
	g.add_child(Control.new())
	g.add_child(hint)
	for a: Array in GameSettings.ACTIONS:
		_label(g, tr(str(a[1])))
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(140, 0)
		b.pressed.connect(_wait_for_key.bind(str(a[0])))
		g.add_child(b)
		_key_buttons[a[0]] = b
	_label(g, tr("고정: 클릭 사격, Esc 메뉴, F3~F8 화면·소리 도구"))
	g.add_child(_button(tr("키 기본값으로"), func() -> void:
		GameSettings.reset_keys()
		_show_keys()
		_note.text = tr("키를 기본값으로 되돌렸다")))
	_show_keys()
	return g.get_parent()


# ---- key capture -----------------------------------------------------------------

func _wait_for_key(action: String) -> void:
	_waiting = action
	_show_keys()
	(_key_buttons[action] as Button).text = tr("키를 누르세요 (Esc 취소)")


func _input(event: InputEvent) -> void:
	if _waiting == "" or not is_visible_in_tree():
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	get_viewport().set_input_as_handled()
	var action := _waiting
	_waiting = ""
	if k.physical_keycode == KEY_ESCAPE:
		_note.text = ""
	else:
		var other := GameSettings.rebind(action, k.physical_keycode)
		if other == "!":
			_note.text = tr("%s 키는 바꿀 수 없다 (메뉴·도구 키)") % GameSettings.key_label(k.physical_keycode)
		elif other != "":
			_note.text = tr("'%s'에 쓰던 키라서 '%s'는 이제 %s 키") % [tr(GameSettings.action_label(other)),
					tr(GameSettings.action_label(other)), GameSettings.key_name(other)]
		else:
			_note.text = ""
	_show_keys()


func _show_keys() -> void:
	for action: String in _key_buttons:
		(_key_buttons[action] as Button).text = GameSettings.key_name(action)


# ---- helpers ---------------------------------------------------------------------

func _change(section: String, key: String, v: Variant) -> void:
	GameSettings.set_value(section, key, v)
	GameSettings.apply_engine(get_viewport())


func _reset_all() -> void:
	GameSettings.reset_all()
	GameSettings.apply_engine(get_viewport())
	for r in _refreshers:
		r.call()
	_show_keys()
	_note.text = tr("모든 설정을 기본값으로 되돌렸다")


## Buttons that read as buttons on the dark panel.
func _theme() -> Theme:
	var t := Theme.new()
	var states := {"normal": Color(0.19, 0.21, 0.26), "hover": Color(0.26, 0.29, 0.36), "pressed": Color(0.3, 0.4, 0.6), "disabled": Color(0.15, 0.15, 0.17)}
	for st: String in states:
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[st]
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		t.set_stylebox(st, "Button", sb)
		t.set_stylebox(st, "OptionButton", sb)
		t.set_stylebox(st, "CheckButton", StyleBoxEmpty.new())
	return t


func _grid(tab_name: String) -> GridContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var g := GridContainer.new()
	g.columns = 2
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 8)
	scroll.add_child(g)
	return g


func _label(g: GridContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(l)


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	return b


func _check(g: GridContainer, text: String, section: String, key: String) -> void:
	_label(g, text)
	var c := CheckButton.new()
	c.focus_mode = Control.FOCUS_NONE
	var show := func() -> void: c.set_pressed_no_signal(bool(GameSettings.value(section, key)))
	show.call()
	_refreshers.append(show)
	c.toggled.connect(func(on: bool) -> void: _change(section, key, on))
	g.add_child(c)


## A slider row; `percent` shows the value as %, otherwise as a number.
func _slider(g: GridContainer, text: String, section: String, key: String, lo: float, hi: float, step: float, percent: bool) -> void:
	_label(g, text)
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(240, 0)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var val := Label.new()
	val.custom_minimum_size = Vector2(52, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var fmt := func(v: float) -> String: return "%d%%" % roundi(v * 100.0) if percent else "%.2f" % v
	var show := func() -> void:
		s.set_value_no_signal(float(GameSettings.value(section, key)))
		val.text = fmt.call(s.value)
	show.call()
	_refreshers.append(show)
	s.value_changed.connect(func(v: float) -> void:
		val.text = fmt.call(v)
		_change(section, key, v))
	row.add_child(s)
	row.add_child(val)
	g.add_child(row)
