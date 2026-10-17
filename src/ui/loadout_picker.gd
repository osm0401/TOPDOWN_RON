extends VBoxContainer
## Briefing gear picks for the local officer: primary weapon, its rounds, two tools; the
## partner's picks below. Buttons send the choice to NetWorld (the host checks it); after Enter
## (ready) they lock. Labels and hints: data/loadout.json. No class_name: preloaded by MissionPanel.

const TEXT := Color(0.92, 0.92, 0.95)
const DIM := Color(0.65, 0.68, 0.75)
const PICKED := Color(0.45, 0.6, 1.0)

var world: NetWorld

var _cfg: Dictionary = {}
var _rows: Dictionary = {}  ## field ("primary", "ammo", "tool0", "tool1") -> {choice: Button}
var _hint: Label
var _partner: Label
var _title: Label


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/loadout.json")
	add_theme_constant_override("separation", 6)
	_title = _label("", 18, Color(1.0, 0.85, 0.4))
	add_child(_title)
	var ch: Dictionary = _cfg["choices"]
	_row("primary", tr("주무기"), ch["primary"])
	_row("ammo", tr("탄약"), ch["ammo"])
	_row("tool0", tr("도구 1"), ch["tools"])
	_row("tool1", tr("도구 2"), ch["tools"])
	_hint = _label("", 14, DIM)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_hint)
	_partner = _label("", 14, DIM)
	_partner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_partner)
	world.loadout_changed.connect(_refresh)
	_refresh()


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


func _row(field: String, title: String, keys: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var name := _label(title, 15, TEXT)
	name.custom_minimum_size = Vector2(70, 0)
	row.add_child(name)
	var buttons := {}
	for k: Variant in keys:
		var b := Button.new()
		b.text = tr(str(_cfg["labels"].get(str(k), str(k))))
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE  # Enter stays "ready", never presses a button
		b.add_theme_font_size_override("font_size", 14)
		_style(b)
		b.pressed.connect(_pick.bind(field, str(k)))
		b.mouse_entered.connect(func() -> void: _hint.text = tr(str(_cfg["hints"].get(str(k), ""))))
		row.add_child(b)
		buttons[str(k)] = b
	add_child(row)
	_rows[field] = buttons


## Picked: filled blue with white text; not picked: dark with a thin outline.
func _style(b: Button) -> void:
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 10.0
		sb.content_margin_right = 10.0
		sb.content_margin_top = 4.0
		sb.content_margin_bottom = 4.0
		var on := state.contains("pressed")
		sb.bg_color = PICKED if on else (Color(0.2, 0.22, 0.28) if state == "hover" else Color(0.12, 0.13, 0.17))
		sb.border_color = PICKED.lightened(0.3) if on else Color(0.3, 0.32, 0.4)
		sb.set_border_width_all(1)
		if state == "disabled":
			sb.bg_color = Color(0.1, 0.1, 0.12)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", DIM)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.4, 0.45))


## The local officer's entry with one field changed, sent to the world.
func _pick(field: String, key: String) -> void:
	var e: Dictionary = (world.loadout[NetWorld.LOADOUT_KEYS[world.my_slot]] as Dictionary).duplicate(true)
	match field:
		"primary", "ammo":
			e[field] = key
		"tool0":
			e["tools"][0] = key
		"tool1":
			e["tools"][1] = key
	world.choose_loadout(e)
	_refresh()  # a client's buttons wait for the host's answer; until then they show what is in force


func _refresh() -> void:
	var me := world.my_slot
	var e: Dictionary = world.loadout.get(NetWorld.LOADOUT_KEYS[me], {})
	if e.is_empty():
		return
	var open := world.can_change_loadout(me)
	_title.text = tr("장비 선택 (클릭)") if open else tr("장비 (준비 완료: 잠김)")
	var current := {"primary": e["primary"], "ammo": e["ammo"], "tool0": e["tools"][0], "tool1": e["tools"][1]}
	for field: String in _rows:
		for k: String in _rows[field]:
			var b: Button = _rows[field][k]
			b.set_pressed_no_signal(k == current[field])
			b.disabled = not open or (field == "ammo" and e["primary"] != "rifle_lethal")  # rounds: the lethal rifle's
	var hints: Dictionary = _cfg["hints"]  # what the gun and its rounds do (a hovered button shows its own)
	_hint.text = tr(str(hints[e["primary"]])) + ((" / " + tr(str(hints[e["ammo"]]))) if e["primary"] == "rifle_lethal" else "")
	if world.solo:
		_partner.text = ""
		return
	var o: Dictionary = world.loadout.get(NetWorld.LOADOUT_KEYS[1 - me], {})
	if not o.is_empty():
		var lb: Dictionary = _cfg["labels"]
		var gun := tr(str(lb[o["primary"]])) + ((" (" + tr(str(lb[o["ammo"]])) + ")") if o["primary"] == "rifle_lethal" else "")
		_partner.text = tr("동료 장비: %s, %s + %s") % [gun, tr(str(lb[o["tools"][0]])), tr(str(lb[o["tools"][1]]))]


func _process(_delta: float) -> void:
	var open := world.can_change_loadout(world.my_slot)
	if open != bool(get_meta("open", true)):  # ready (Enter) locks the buttons
		set_meta("open", open)
		_refresh()
