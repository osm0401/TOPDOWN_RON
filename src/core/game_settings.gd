class_name GameSettings
extends RefCounted
## Player settings: volumes, graphics, mouse sensitivity and key bindings. Kept in
## user://settings.cfg (a ConfigFile) and shared by the whole process (static).
## Readers that cache something (the 3D view's graphics level, the music bus) compare
## `revision` each frame and re-apply when it changed.

const DEFAULTS := {
	"audio": {"master": 1.0, "sfx": 1.0, "music": 0.6},
	"graphics": {"quality": "", "fullscreen": false, "vsync": true, "max_fps": 0, "render_scale": 1.0, "shake": 1.0},
	"controls": {"sensitivity": 1.0},
}
## Limits for the number settings: [min, max].
const RANGES := {
	"audio/master": [0.0, 1.0], "audio/sfx": [0.0, 1.0], "audio/music": [0.0, 1.0],
	"graphics/max_fps": [0, 300], "graphics/render_scale": [0.5, 1.0], "graphics/shake": [0.0, 2.0],
	"controls/sensitivity": [0.2, 3.0],
}
## Rebindable keyboard actions: [name, label, default physical key]. Esc (menu) and the
## F-keys (debug views) stay fixed; firing stays on the left mouse button.
const ACTIONS: Array = [
	["move_up", "앞으로", KEY_W], ["move_down", "뒤로", KEY_S], ["move_left", "왼쪽", KEY_A], ["move_right", "오른쪽", KEY_D],
	["reload", "재장전", KEY_R], ["swap", "무기 교체", KEY_Q], ["interact", "문·구속·락픽 (Shift: 살짝 열기)", KEY_E],
	["kick", "발로 차기", KEY_X], ["camera", "문틈 카메라", KEY_C], ["taser", "테이저", KEY_T],
	["flashlight", "손전등", KEY_F], ["laser", "레이저", KEY_L], ["report", "증거 줍기·무전 보고", KEY_V], ["ready", "준비 완료", KEY_ENTER],
	["command_1", "명령 1 (결과: 다시 하기)", KEY_1], ["command_2", "명령 2 (결과: 로비로)", KEY_2],
	["command_3", "명령 3", KEY_3], ["command_4", "명령 4", KEY_4],
]
const FIXED_KEYS: Array[int] = [KEY_ESCAPE, KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12]

static var path := "user://settings.cfg"
static var revision := 0  ## bumped on every change
static var _values: Dictionary = {}
static var _keys: Dictionary = {}  ## action -> physical keycode
static var _loaded := false


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	reset_all()
	load_file()


## Back to the defaults (not saved until save_file).
static func reset_all() -> void:
	_values = DEFAULTS.duplicate(true)
	reset_keys()


static func reset_keys() -> void:
	_keys.clear()
	for a: Array in ACTIONS:
		_keys[a[0]] = int(a[2])
	revision += 1


## Reads the file at `p` over the current values; unknown or broken entries are skipped.
static func load_file(p := "") -> void:
	if p == "":
		p = path
	_loaded = true
	var cf := ConfigFile.new()
	if cf.load(p) != OK:
		return
	for section: String in DEFAULTS:
		for key: String in DEFAULTS[section]:
			if cf.has_section_key(section, key):
				_store(section, key, cf.get_value(section, key))
	for a: Array in ACTIONS:
		if cf.has_section_key("keys", a[0]):
			var code := int(cf.get_value("keys", a[0]))
			if code > 0 and not code in FIXED_KEYS:
				_keys[a[0]] = code
	revision += 1


static func save_file(p := "") -> int:
	_ensure()
	if p == "":
		p = path
	var cf := ConfigFile.new()
	for section: String in _values:
		for key: String in _values[section]:
			cf.set_value(section, key, _values[section][key])
	for action: String in _keys:
		cf.set_value("keys", action, _keys[action])
	return cf.save(p)


static func value(section: String, key: String) -> Variant:
	_ensure()
	return _values[section][key]


static func set_value(section: String, key: String, v: Variant) -> void:
	_ensure()
	_store(section, key, v)
	revision += 1


## Stores v with the default's type, clamped to RANGES.
static func _store(section: String, key: String, v: Variant) -> void:
	var def: Variant = DEFAULTS[section][key]
	var r: Array = RANGES.get(section + "/" + key, [])
	match typeof(def):
		TYPE_BOOL:
			v = bool(v)
		TYPE_INT:
			v = int(v)
			if not r.is_empty():
				v = clampi(v, int(r[0]), int(r[1]))
		TYPE_FLOAT:
			v = float(v)
			if not r.is_empty():
				v = clampf(v, float(r[0]), float(r[1]))
		_:
			v = str(v)
	_values[section][key] = v


# ---- key bindings ---------------------------------------------------------------

static func key(action: String) -> int:
	_ensure()
	return int(_keys.get(action, KEY_NONE))


## The action bound to a physical key, "" when none.
static func action_for(code: int) -> String:
	_ensure()
	for action: String in _keys:
		if int(_keys[action]) == code:
			return action
	return ""


static func pressed(action: String) -> bool:
	return Input.is_physical_key_pressed(key(action) as Key)


## Binds `code` to `action`. A key another action had is handed over: that action gets
## this one's old key. Returns that other action ("" when the key was free), or "!" when
## the key is reserved (Esc, F-keys) and nothing changed.
static func rebind(action: String, code: int) -> String:
	_ensure()
	if code in FIXED_KEYS or code == KEY_NONE or not _keys.has(action):
		return "!"
	var other := action_for(code)
	if other != "" and other != action:
		_keys[other] = _keys[action]
	_keys[action] = code
	revision += 1
	return other if other != action else ""


static func key_name(action: String) -> String:
	return key_label(key(action))


static func key_label(code: int) -> String:
	return OS.get_keycode_string(code) if code != KEY_NONE else "-"


static func action_label(action: String) -> String:
	for a: Array in ACTIONS:
		if a[0] == action:
			return str(a[1])
	return action


# ---- applying -------------------------------------------------------------------

## Pushes the settings the engine holds: master volume, window mode, vsync, frame cap,
## 3D render scale. The rest is read where it is used.
static func apply_engine(vp: Viewport = null) -> void:
	_ensure()
	AudioServer.set_bus_volume_db(0, volume_db(float(value("audio", "master"))))
	Engine.max_fps = int(value("graphics", "max_fps"))
	if vp != null:
		vp.scaling_3d_scale = float(value("graphics", "render_scale"))
	if DisplayServer.get_name() == "headless":
		return
	var fs := bool(value("graphics", "fullscreen"))
	var mode := DisplayServer.window_get_mode()
	if fs and mode != DisplayServer.WINDOW_MODE_FULLSCREEN and mode != DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not fs and (mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(value("graphics", "vsync")) else DisplayServer.VSYNC_DISABLED)


## A 0..1 slider as a bus volume: 0 is silence.
static func volume_db(v: float) -> float:
	return linear_to_db(v) if v > 0.001 else -80.0


## Mouse sensitivity (AimCursor): where the crosshair at `at` goes after a mouse motion of
## `rel` px at sensitivity `sens`, kept inside `rect`.
static func aim_moved(at: Vector2, rel: Vector2, sens: float, rect: Rect2) -> Vector2:
	return (at + rel * sens).clamp(rect.position, rect.end - Vector2.ONE)
