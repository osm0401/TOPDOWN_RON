extends Node
## Lobby (host / join by room code) and NetWorld lifecycle.
## Test flags (after "--"): --auto-host, --auto-join  (localhost room code, scripted play).

var _lobby: Control
var _status: Label
var _code_edit: LineEdit
var _world: NetWorld
var _auto_role := ""


func _ready() -> void:
	_build_lobby()
	Session.client_connected.connect(_enter_world)
	Session.join_failed.connect(_show_status)
	Session.connection_lost.connect(_leave_to_lobby)
	_run_auto.call_deferred()


func _build_lobby() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_lobby = CenterContainer.new()
	_lobby.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_lobby)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 10)
	_lobby.add_child(box)

	var title := Label.new()
	title.text = tr("2인 협동 CQB 프로토타입 (단계 1: 온라인 연결 시험)")
	box.add_child(title)

	var host_btn := Button.new()
	host_btn.text = tr("방 만들기")
	host_btn.pressed.connect(_on_host_pressed)
	box.add_child(host_btn)

	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = tr("방 코드 입력 (XXXX-XXXX-XXXX)")
	_code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	box.add_child(_code_edit)

	var join_btn := Button.new()
	join_btn.text = tr("코드로 참가")
	join_btn.pressed.connect(_on_join_pressed)
	box.add_child(join_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)


func _on_host_pressed() -> void:
	if Session.host() == "":
		_show_status(tr("방을 만들 수 없습니다 (포트가 이미 사용 중일 수 있음)"))
		return
	_enter_world()


func _on_join_pressed() -> void:
	_show_status(tr("접속 중..."))
	Session.join(_code_edit.text)


func _show_status(msg: String) -> void:
	_status.text = msg


func _enter_world() -> void:
	if _world != null:
		return
	_world = NetWorld.new()
	_world.name = "World"
	_world.auto_role = _auto_role
	_world.leave_requested.connect(_leave_to_lobby.bind(""))
	add_child(_world)
	_lobby.hide()


func _leave_to_lobby(msg: String) -> void:
	Session.leave()
	if _world != null:
		remove_child(_world)
		_world.queue_free()
		_world = null
	_lobby.show()
	_show_status(msg)


func _run_auto() -> void:
	var args := OS.get_cmdline_user_args()
	if "--auto-host" in args:
		_auto_role = "host"
		if Session.host(true) == "":
			get_tree().quit(1)
			return
		_enter_world()
	elif "--auto-join" in args:
		_auto_role = "client"
		var port := int(Session.cfg.get("port", 0))
		Session.join(RoomCode.encode("127.0.0.1", port))
