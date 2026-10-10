class_name NetWorld
extends Node2D
## Stage-1 online sample: 2 players, 1 door, 1 NPC (state sample), 1 team score (sample).
## Host-authoritative: client sends input/requests, host simulates and replicates.
## Auto test mode (auto_role = "host"/"client") replays a fixed script and prints FINAL state.

signal leave_requested

const SLOT_HOST := 0
const SLOT_CLIENT := 1
const NPC_IDLE := 0
const NPC_ALERT := 1
const AUTO_EVENTS := {
	"host": [[2.2, "door"], [3.8, "door"], [4.2, "score"]],
	"client": [[3.0, "door"], [4.0, "score"]],
}
const COLORS: Array[Color] = [Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.2)]

var auto_role := ""

var _speed := 0.0
var _door_range := 0.0
var _npc_range := 0.0
var _snap_interval := 0.05
var _ping_interval := 1.0
var _arena := Rect2(0, 60, 1280, 660)
var _door_pos := Vector2(600, 390)
var _npc_pos := Vector2(900, 390)

var _pos: Array[Vector2] = [Vector2(100, 340), Vector2(100, 440)]
var _shown: Array[Vector2] = [Vector2(100, 340), Vector2(100, 440)]
var _aim: Array[float] = [0.0, 0.0]
var _door_open := false
var _npc := NPC_IDLE
var _score := 0

var _is_host := false
var _my_slot := 0
var _client_id := 0
var _client_move := Vector2.ZERO
var _running := false
var _have_snap := false
var _t := 0.0
var _snap_accum := 0.0
var _ping_accum := 0.0
var _rtt_ms := -1
var _snap_count := 0
var _auto_done: Dictionary = {}
var _hud: Label


func _ready() -> void:
	var tuning := JsonData.load_dict("res://data/tuning.json")
	_speed = float(tuning.get("move_speed", 0.0))
	_door_range = float(tuning.get("door_range", 0.0))
	_npc_range = float(tuning.get("npc_alert_range", 0.0))
	_snap_interval = 1.0 / float(Session.cfg.get("tick_hz", 20))
	_ping_interval = float(Session.cfg.get("ping_interval_s", 1.0))
	_is_host = Session.is_hosting
	_my_slot = SLOT_HOST if _is_host else SLOT_CLIENT
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 8)
	layer.add_child(_hud)
	if not _is_host:
		rpc_client_ready.rpc_id(1)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_E:
			_request_door()
		KEY_F:
			_request_score()
		KEY_ESCAPE:
			leave_requested.emit()


func _physics_process(delta: float) -> void:
	if not _running:
		return
	_t += delta
	var local := _local_input()
	_aim[_my_slot] = local.aim
	if _is_host:
		_step_host(delta, local.move)
	else:
		_snap_accum += delta
		if _snap_accum >= _snap_interval:
			_snap_accum = 0.0
			rpc_input.rpc_id(1, local.move, local.aim)
		_ping_accum += delta
		if _ping_accum >= _ping_interval:
			_ping_accum = 0.0
			rpc_ping.rpc_id(1, Time.get_ticks_msec())
	_auto_tick()


func _process(delta: float) -> void:
	for s in 2:
		_shown[s] = _shown[s].lerp(_pos[s], minf(delta * 15.0, 1.0))
	_update_hud()
	queue_redraw()


func _draw() -> void:
	draw_rect(_arena, Color(0.12, 0.12, 0.12), true)
	draw_rect(_arena, Color.GRAY, false, 2.0)
	var door_rect := Rect2(_door_pos - Vector2(10, 60), Vector2(20, 120))
	draw_rect(door_rect, Color.GREEN if _door_open else Color.RED, not _door_open)
	draw_circle(_npc_pos, 16.0, Color.YELLOW if _npc == NPC_ALERT else Color.GRAY)
	for s in 2:
		var p := _display_pos(s)
		draw_circle(p, 14.0, COLORS[s])
		draw_line(p, p + Vector2.from_angle(_aim[s]) * 30.0, Color.WHITE, 3.0)
		if s == _my_slot:
			draw_arc(p, 20.0, 0.0, TAU, 24, Color.WHITE, 1.5)


func _display_pos(slot: int) -> Vector2:
	return _pos[slot] if _is_host else _shown[slot]


func _local_input() -> Dictionary:
	if auto_role != "":
		return {"move": _auto_move(), "aim": 0.0}
	var m := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var a := (get_global_mouse_position() - _display_pos(_my_slot)).angle()
	return {"move": m.limit_length(1.0), "aim": a}


# ---- host simulation -------------------------------------------------------

func _step_host(delta: float, host_move: Vector2) -> void:
	var moves: Array[Vector2] = [host_move, _client_move]
	for s in 2:
		_pos[s] = (_pos[s] + moves[s] * _speed * delta).clamp(_arena.position, _arena.end)
	var near := _pos[0].distance_to(_npc_pos) < _npc_range or _pos[1].distance_to(_npc_pos) < _npc_range
	var npc := NPC_ALERT if near else NPC_IDLE
	if npc != _npc:
		_npc = npc
		_push_state()
	_snap_accum += delta
	if _snap_accum >= _snap_interval:
		_snap_accum = 0.0
		rpc_snapshot.rpc(_pos[0], _pos[1], _aim[0], _aim[1])


func _try_door(slot: int) -> void:
	if _pos[slot].distance_to(_door_pos) > _door_range:
		Session.log_line("door request rejected slot=%d (too far)" % slot)
		return
	_door_open = not _door_open
	_push_state()


func _add_score() -> void:
	_score += 10
	_push_state()


func _push_state() -> void:
	if _running:
		rpc_state.rpc(_door_open, _npc, _score)


# ---- requests (local player) ----------------------------------------------

func _request_door() -> void:
	if not _running:
		return
	if _is_host:
		_try_door(SLOT_HOST)
	else:
		rpc_request_door.rpc_id(1)


func _request_score() -> void:
	if not _running:
		return
	if _is_host:
		_add_score()
	else:
		rpc_request_score.rpc_id(1)


# ---- RPC -------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func rpc_client_ready() -> void:
	if not _is_host or _running:
		return
	_client_id = multiplayer.get_remote_sender_id()
	_running = true
	_t = 0.0
	Session.log_line("client ready id=%d" % _client_id)
	rpc_state.rpc_id(_client_id, _door_open, _npc, _score)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_input(move: Vector2, aim: float) -> void:
	if not _is_host or multiplayer.get_remote_sender_id() != _client_id:
		return
	if not move.is_finite() or not is_finite(aim):
		return
	_client_move = move.limit_length(1.0)
	_aim[SLOT_CLIENT] = aim


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_door() -> void:
	if _is_host and _running and multiplayer.get_remote_sender_id() == _client_id:
		_try_door(SLOT_CLIENT)


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_score() -> void:
	if _is_host and _running and multiplayer.get_remote_sender_id() == _client_id:
		_add_score()


@rpc("any_peer", "call_remote", "unreliable")
func rpc_ping(sent_ms: int) -> void:
	if _is_host:
		rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), sent_ms)


@rpc("authority", "call_remote", "unreliable")
func rpc_pong(sent_ms: int) -> void:
	_rtt_ms = Time.get_ticks_msec() - sent_ms
	Session.log_line("rtt=%dms snapshots=%d" % [_rtt_ms, _snap_count])
	_snap_count = 0


@rpc("authority", "call_remote", "reliable")
func rpc_state(door: bool, npc: int, score: int) -> void:
	_door_open = door
	_npc = npc
	_score = score
	_running = true


@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_snapshot(p0: Vector2, p1: Vector2, a0: float, a1: float) -> void:
	_pos[0] = p0
	_pos[1] = p1
	_aim[SLOT_HOST] = a0
	if not _have_snap:
		_have_snap = true
		_shown[0] = p0
		_shown[1] = p1
	_snap_count += 1


# ---- HUD -------------------------------------------------------------------

func _update_hud() -> void:
	if _is_host and not _running:
		if Session.room_code == "":
			_hud.text = Session.host_note
		else:
			_hud.text = tr("방 코드: %s\n상대 플레이어 대기 중...") % Session.room_code + "\n" + Session.host_note
		return
	var rtt := tr("호스트") if _is_host else "%d ms" % _rtt_ms
	_hud.text = tr("이동 WASD / 조준 마우스 / E 문 / F 점수(샘플) / Esc 나가기\n문: %s   적(샘플): %s   점수(샘플): %d   RTT: %s") % [
		tr("열림") if _door_open else tr("닫힘"),
		tr("경계") if _npc == NPC_ALERT else tr("대기"),
		_score,
		rtt,
	]


# ---- auto test -------------------------------------------------------------

func _auto_move() -> Vector2:
	if _t < 2.0:
		return Vector2.RIGHT
	if auto_role == "host" and _t >= 4.4 and _t < 5.4:
		return Vector2.RIGHT
	return Vector2.ZERO


func _auto_tick() -> void:
	if auto_role == "":
		return
	var events: Array = AUTO_EVENTS[auto_role]
	for i in events.size():
		if _t >= events[i][0] and not _auto_done.has(i):
			_auto_done[i] = true
			if events[i][1] == "door":
				_request_door()
			else:
				_request_score()
	if _t >= 7.0 and not _auto_done.has("final"):
		_auto_done["final"] = true
		Session.log_line("FINAL p0=%.1f,%.1f p1=%.1f,%.1f door=%s npc=%d score=%d" % [
			_pos[0].x, _pos[0].y, _pos[1].x, _pos[1].y, _door_open, _npc, _score])
	if _t >= 7.5:
		get_tree().quit()
