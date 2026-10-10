class_name NetWorld
extends Node2D
## Online gray-box world (stage 2): 2 players, 6 doors, 1 NPC (state sample), pistol, sound events.
## Host-authoritative: the client sends input/requests, the host simulates and replicates.
## Rendering lives in WorldView. Auto test mode (auto_role) replays a fixed script and prints FINAL.

signal leave_requested
signal sound_emitted(kind: int, pos: Vector2)
signal shot_fired(slot: int, from: Vector2, to: Vector2, hit_npc: bool)

enum Sound { FOOTSTEP, GUNSHOT, DOOR }

const SLOT_HOST := 0
const SLOT_CLIENT := 1
const NPC_IDLE := 0
const NPC_ALERT := 1
const PLAYER_RADIUS := 14.0
const AUTO_EVENTS := {
	"host": [[0.3, "door"], [5.4, "fire"], [5.7, "fire"], [6.0, "reload"], [6.2, "score"]],
	"client": [[5.2, "door"], [5.8, "fire"], [6.1, "reload"], [6.4, "score"]],
}

var auto_role := ""
var shot_path := ""

var level: Level
var pos: Array[Vector2] = []
var shown: Array[Vector2] = []
var aim: Array[float] = [0.0, 0.0]
var weapons: Array[WeaponState] = []
var npc := NPC_IDLE
var score := 0
var is_host := false
var my_slot := 0
var running := false
var rtt_ms := -1
var view_radius := 700.0
var npc_radius := 16.0
var sound_radius: Dictionary = {}

var _speed := 0.0
var _door_range := 0.0
var _npc_range := 0.0
var _stride_px := 60.0
var _pistol_range := 900.0
var _snap_interval := 0.05
var _ping_interval := 1.0
var _bodies: Array[CharacterBody2D] = []
var _stride: Array[float] = [0.0, 0.0]
var _client_id := 0
var _client_move := Vector2.ZERO
var _have_snap := false
var _t := 0.0
var _snap_accum := 0.0
var _ping_accum := 0.0
var _snap_count := 0
var _auto_done: Dictionary = {}


func _ready() -> void:
	var tuning := JsonData.load_dict("res://data/tuning.json")
	_speed = float(tuning["move_speed"])
	_door_range = float(tuning["door_range"])
	_npc_range = float(tuning["npc_alert_range"])
	_stride_px = float(tuning["footstep_stride_px"])
	view_radius = float(tuning["view_radius"])
	npc_radius = float(tuning["npc_radius"])
	sound_radius = tuning["sound_radius"]
	var gun: Dictionary = tuning["pistol"]
	_pistol_range = float(gun["range"])
	for s in 2:
		weapons.append(WeaponState.create(int(gun["mag_size"]), int(gun["spare_mags"]),
				float(gun["fire_interval_s"]), float(gun["reload_s"])))
	_snap_interval = 1.0 / float(Session.cfg.get("tick_hz", 20))
	_ping_interval = float(Session.cfg.get("ping_interval_s", 1.0))
	is_host = Session.is_hosting
	my_slot = SLOT_HOST if is_host else SLOT_CLIENT

	level = Level.new()
	level.name = "Level"
	add_child(level)
	level.load_map("res://data/map_01.json")
	pos.assign([level.spawns[0], level.spawns[1]])
	shown.assign(pos)
	if is_host:
		for s in 2:
			_bodies.append(_make_body(pos[s]))

	var view := WorldView.new()
	view.name = "View"
	view.world = self
	add_child(view)
	if not is_host:
		rpc_client_ready.rpc_id(1)


func display_pos(slot: int) -> Vector2:
	return pos[slot] if is_host else shown[slot]


func _make_body(at: Vector2) -> CharacterBody2D:
	var b := CharacterBody2D.new()
	b.collision_layer = 2
	b.collision_mask = Level.WALL_LAYER
	b.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	b.position = at
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = PLAYER_RADIUS
	cs.shape = shape
	b.add_child(cs)
	add_child(b)
	return b


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_request_fire()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_E:
				_request_door()
			KEY_F:
				_request_score()
			KEY_R:
				_request_reload()
			KEY_ESCAPE:
				leave_requested.emit()


func _physics_process(delta: float) -> void:
	if not running:
		return
	_t += delta
	var local := _local_input()
	aim[my_slot] = local.aim
	if is_host:
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
		shown[s] = shown[s].lerp(pos[s], minf(delta * 15.0, 1.0))


func _local_input() -> Dictionary:
	if auto_role != "":
		return {"move": _auto_move(), "aim": 0.0}
	var m := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var a := (get_global_mouse_position() - display_pos(my_slot)).angle()
	return {"move": m.limit_length(1.0), "aim": a}


# ---- host simulation -------------------------------------------------------

func _step_host(delta: float, host_move: Vector2) -> void:
	var moves: Array[Vector2] = [host_move, _client_move]
	for s in 2:
		var b := _bodies[s]
		b.velocity = moves[s] * _speed
		b.move_and_slide()
		pos[s] = b.position
		_stride[s] += b.get_real_velocity().length() * delta
		if _stride[s] >= _stride_px:
			_stride[s] = 0.0
			_emit_sound(Sound.FOOTSTEP, pos[s])
	for s in 2:
		if weapons[s].update(delta):
			_push_weapons()
	var alert := false
	for s in 2:
		if pos[s].distance_to(level.npc_pos) < _npc_range and level.has_los(level.npc_pos, pos[s]):
			alert = true
	var state := NPC_ALERT if alert else NPC_IDLE
	if state != npc:
		npc = state
		_push_state()
	_snap_accum += delta
	if _snap_accum >= _snap_interval:
		_snap_accum = 0.0
		rpc_snapshot.rpc(pos[0], pos[1], aim[0], aim[1])


func _try_door(slot: int) -> void:
	var i := level.nearest_door(pos[slot], _door_range)
	if i < 0:
		Session.log_line("door request rejected slot=%d (no door in range)" % slot)
		return
	level.toggle_door(i, slot + 1)
	_emit_sound(Sound.DOOR, level.door_rects[i].get_center())
	_push_state()


func _host_fire(slot: int, angle: float) -> void:
	if not weapons[slot].try_fire():
		return
	var dir := Vector2.from_angle(angle)
	var from := pos[slot] + dir * 20.0
	var to := from + dir * _pistol_range
	var hit := level.ray_hit(from, to)
	if not hit.is_empty():
		to = hit["position"]
	var closest := Geometry2D.get_closest_point_to_segment(level.npc_pos, from, to)
	var npc_hit := closest.distance_to(level.npc_pos) <= npc_radius
	if npc_hit:
		to = closest
	_apply_shot(slot, from, to, npc_hit)
	rpc_shot.rpc(slot, from, to, npc_hit)
	_emit_sound(Sound.GUNSHOT, from)
	_push_weapons()


func _apply_shot(slot: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	shot_fired.emit(slot, from, to, hit_npc)


func _emit_sound(kind: int, at: Vector2) -> void:
	sound_emitted.emit(kind, at)
	if running:
		rpc_sound.rpc(kind, at)


func _push_state() -> void:
	if running:
		rpc_state.rpc(level.pack_doors(), npc, score)


func _push_weapons() -> void:
	if running:
		rpc_weapons.rpc(weapons[0].to_packed(), weapons[1].to_packed())


# ---- requests from the local player ---------------------------------------

func _request_door() -> void:
	if not running:
		return
	if is_host:
		_try_door(SLOT_HOST)
	else:
		rpc_request_door.rpc_id(1)


func _request_score() -> void:
	if not running:
		return
	if is_host:
		score += 10
		_push_state()
	else:
		rpc_request_score.rpc_id(1)


func _request_fire() -> void:
	if not running:
		return
	if is_host:
		_host_fire(SLOT_HOST, aim[SLOT_HOST])
	else:
		rpc_fire.rpc_id(1, aim[SLOT_CLIENT])


func _request_reload() -> void:
	if not running:
		return
	if is_host:
		if weapons[SLOT_HOST].start_reload():
			_push_weapons()
	else:
		rpc_reload.rpc_id(1)


# ---- RPC -------------------------------------------------------------------

func _from_client() -> bool:
	return is_host and running and multiplayer.get_remote_sender_id() == _client_id


@rpc("any_peer", "call_remote", "reliable")
func rpc_client_ready() -> void:
	if not is_host or running:
		return
	_client_id = multiplayer.get_remote_sender_id()
	running = true
	_t = 0.0
	Session.log_line("client ready id=%d" % _client_id)
	rpc_state.rpc_id(_client_id, level.pack_doors(), npc, score)
	rpc_weapons.rpc_id(_client_id, weapons[0].to_packed(), weapons[1].to_packed())


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_input(move: Vector2, angle: float) -> void:
	if not _from_client() or not move.is_finite() or not is_finite(angle):
		return
	_client_move = move.limit_length(1.0)
	aim[SLOT_CLIENT] = angle


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_door() -> void:
	if _from_client():
		_try_door(SLOT_CLIENT)


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_score() -> void:
	if _from_client():
		score += 10
		_push_state()


@rpc("any_peer", "call_remote", "reliable")
func rpc_fire(angle: float) -> void:
	if _from_client() and is_finite(angle):
		_host_fire(SLOT_CLIENT, angle)


@rpc("any_peer", "call_remote", "reliable")
func rpc_reload() -> void:
	if _from_client() and weapons[SLOT_CLIENT].start_reload():
		_push_weapons()


@rpc("any_peer", "call_remote", "unreliable")
func rpc_ping(sent_ms: int) -> void:
	if is_host:
		rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), sent_ms)


@rpc("authority", "call_remote", "unreliable")
func rpc_pong(sent_ms: int) -> void:
	rtt_ms = Time.get_ticks_msec() - sent_ms
	Session.log_line("rtt=%dms snapshots=%d" % [rtt_ms, _snap_count])
	_snap_count = 0


@rpc("authority", "call_remote", "reliable")
func rpc_state(doors: PackedInt32Array, npc_state: int, score_value: int) -> void:
	level.unpack_doors(doors)
	npc = npc_state
	score = score_value
	running = true


@rpc("authority", "call_remote", "reliable")
func rpc_weapons(a: PackedInt32Array, b: PackedInt32Array) -> void:
	weapons[0].from_packed(a)
	weapons[1].from_packed(b)


@rpc("authority", "call_remote", "reliable")
func rpc_shot(slot: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	_apply_shot(slot, from, to, hit_npc)


@rpc("authority", "call_remote", "reliable")
func rpc_sound(kind: int, at: Vector2) -> void:
	sound_emitted.emit(kind, at)


@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_snapshot(p0: Vector2, p1: Vector2, a0: float, a1: float) -> void:
	pos[0] = p0
	pos[1] = p1
	aim[SLOT_HOST] = a0
	if not _have_snap:
		_have_snap = true
		shown[0] = p0
		shown[1] = p1
	_snap_count += 1


# ---- auto test -------------------------------------------------------------

func _auto_move() -> Vector2:
	return Vector2.RIGHT if _t >= 0.5 and _t < 5.2 else Vector2.ZERO


func _auto_tick() -> void:
	if auto_role == "":
		return
	var events: Array = AUTO_EVENTS[auto_role]
	for i in events.size():
		if _t >= events[i][0] and not _auto_done.has(i):
			_auto_done[i] = true
			match events[i][1]:
				"door":
					_request_door()
				"score":
					_request_score()
				"fire":
					_request_fire()
				"reload":
					_request_reload()
	if shot_path != "" and _t >= 5.45 and not _auto_done.has("shot"):
		_auto_done["shot"] = true
		_capture(shot_path)
	if _t >= 8.0 and not _auto_done.has("final"):
		_auto_done["final"] = true
		Session.log_line("FINAL p0=%.1f,%.1f p1=%.1f,%.1f doors=%s npc=%d score=%d w0=%s w1=%s" % [
			pos[0].x, pos[0].y, pos[1].x, pos[1].y, level.pack_doors(), npc, score,
			weapons[0].to_packed(), weapons[1].to_packed()])
	if _t >= 8.5:
		get_tree().quit()


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	Session.log_line("screenshot saved")
