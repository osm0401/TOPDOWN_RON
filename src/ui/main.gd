extends Node
## Lobby (host / join by room code) and NetWorld lifecycle.
## Test flags (after "--"): --auto-host, --auto-join  (localhost room code, scripted play).

const CharacterModels := preload("res://src/game/character_models.gd")
const GearModels := preload("res://src/game/gear_models.gd")

var _lobby: Control
var _status: Label
var _code_edit: LineEdit
var _world: NetWorld
var _auto_role := ""
var _shot_path := ""
var _scenario := ""
var _generation := 0  ## incremented on every retry so a fresh world can tell it is a restart


func _ready() -> void:
	_build_lobby()
	Session.client_connected.connect(_enter_world)
	Session.join_failed.connect(_show_status)
	Session.connection_lost.connect(_leave_to_lobby)
	GameAudio.prepare()  # the stand-in sounds are synthesized in the background while the lobby is up
	_run_auto.call_deferred()


func _exit_tree() -> void:
	GameAudio.wait_prepared()  # never leave the worker task running at quit
	CharacterModels.release()
	GearModels.release()


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
	title.text = tr("CQB 전술 협동 프로토타입")
	box.add_child(title)

	var diff_box := OptionButton.new()
	for key in ["easy", "normal", "hard"]:
		diff_box.add_item({"easy": tr("난이도: 쉬움"), "normal": tr("난이도: 보통"), "hard": tr("난이도: 어려움")}[key])
		diff_box.set_item_metadata(diff_box.item_count - 1, key)
	diff_box.select(1)
	diff_box.item_selected.connect(func(i: int) -> void: Session.difficulty = str(diff_box.get_item_metadata(i)))
	box.add_child(diff_box)

	box.add_child(HSeparator.new())
	var solo_title := Label.new()
	solo_title.text = tr("싱글 플레이 (혼자)  -  장비 선택")
	box.add_child(solo_title)
	var gear := HBoxContainer.new()
	box.add_child(gear)
	gear.add_child(_gear_box(["rifle_lethal", "rifle_nonlethal"], [tr("살상 소총"), tr("비살상 소총")], str(Session.solo_loadout["primary"]), _on_solo_primary))
	for slot in 2:
		gear.add_child(_gear_box(["camera", "lockpick", "taser"], [tr("문틈 카메라"), tr("락픽"), tr("테이저")], str(Session.solo_loadout["tools"][slot]), _on_solo_tool.bind(slot)))
	var solo_btn := Button.new()
	solo_btn.text = tr("혼자 하기")
	solo_btn.pressed.connect(_on_solo_pressed)
	box.add_child(solo_btn)

	box.add_child(HSeparator.new())
	var host_btn := Button.new()
	host_btn.text = tr("방 만들기 (2인 협동)")
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


func _gear_box(keys: Array, labels: Array, current: String, on_pick: Callable) -> OptionButton:
	var ob := OptionButton.new()
	for i in keys.size():
		ob.add_item(str(labels[i]))
		ob.set_item_metadata(i, keys[i])
		if keys[i] == current:
			ob.select(i)
	ob.item_selected.connect(func(i: int) -> void: on_pick.call(str(ob.get_item_metadata(i))))
	return ob


func _on_solo_primary(kind: String) -> void:
	Session.solo_loadout["primary"] = kind


func _on_solo_tool(kind: String, slot: int) -> void:
	Session.solo_loadout["tools"][slot] = kind


func _on_solo_pressed() -> void:
	Session.start_solo()
	_enter_world()


func _on_host_pressed() -> void:
	if not Session.host():
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
	_world.shot_path = _shot_path
	_world.scenario = _scenario
	_world.generation = _generation
	_world.leave_requested.connect(_leave_to_lobby.bind(""))
	_world.restart_requested.connect(_restart_world, CONNECT_DEFERRED)
	_world.lobby_requested.connect(_on_lobby_requested)
	add_child(_world)
	_lobby.hide()


## Vote chose "retry": rebuild the world on both sides; the connection stays open.
func _restart_world() -> void:
	if _world == null:
		return
	remove_child(_world)
	_world.queue_free()
	_world = null
	_generation += 1
	_enter_world()


## Vote chose "lobby": let the other player's message arrive first, then leave.
func _on_lobby_requested() -> void:
	if not Session.solo:
		await get_tree().create_timer(0.4).timeout
	_leave_to_lobby("")


func _leave_to_lobby(msg: String) -> void:
	Session.leave()
	if _world != null:
		remove_child(_world)
		_world.queue_free()
		_world = null
	_lobby.show()
	_show_status(msg)
	if _auto_role != "":  # scripted test run: the host finished first, nothing more to do
		get_tree().quit()


func _run_auto() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a.begins_with("--difficulty="):
			Session.difficulty = a.substr(13)
		elif a.begins_with("--scenario="):
			_scenario = a.substr(11)
		elif a.begins_with("--lobby-shot="):
			_lobby_shot(a.substr(13))
	if "--solo" in args:
		if _scenario != "":
			_auto_role = "host"
		Session.start_solo()
		_enter_world()
	elif "--auto-host" in args:
		_auto_role = "host"
		if not Session.host("--vpn" not in args):
			get_tree().quit(1)
			return
		_enter_world()
	elif "--auto-join" in args:
		_auto_role = "client"
		var code := RoomCode.encode("127.0.0.1", int(Session.cfg.get("port", 0)))
		for a in args:
			if a.begins_with("--code="):
				code = a.substr(7)
		Session.join(code)


## Test aid: save a screenshot of the lobby and quit.
func _lobby_shot(path: String) -> void:
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
