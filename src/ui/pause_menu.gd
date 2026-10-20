class_name PauseMenu
extends Control
## Esc during a mission: continue, settings, or leave the mission. The game keeps running
## (it is shared with the partner), but your officer stands still while the menu is open.

var world: NetWorld

var _main: VBoxContainer
var _settings: SettingsPanel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var holder := VBoxContainer.new()
	center.add_child(holder)
	_main = VBoxContainer.new()
	_main.custom_minimum_size = Vector2(280, 0)
	_main.add_theme_constant_override("separation", 10)
	holder.add_child(_main)
	var title := Label.new()
	title.text = tr("일시 정지 (게임은 계속 진행된다)") if not world.solo else tr("메뉴")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main.add_child(title)
	_main.add_child(_button(tr("계속하기"), close))
	_main.add_child(_button(tr("설정"), _open_settings))
	_main.add_child(_button(tr("임무 나가기"), func() -> void:
		close()
		world.leave_requested.emit()))
	_settings = SettingsPanel.new()
	_settings.visible = false
	_settings.closed.connect(_close_settings)
	holder.add_child(_settings)


func open() -> void:
	visible = true
	_main.visible = true
	_settings.visible = false
	world.input_blocked = true


func close() -> void:
	if _settings.visible:
		_settings.close()
	visible = false
	world.input_blocked = false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if _settings.visible:
			_settings.close()  # back to the menu
		else:
			close()


func _open_settings() -> void:
	_main.visible = false
	_settings.visible = true


func _close_settings() -> void:
	_settings.visible = false
	_main.visible = true


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	return b
