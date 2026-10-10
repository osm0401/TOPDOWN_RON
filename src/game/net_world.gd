class_name NetWorld
extends Node2D
## Online gray-box world (stage 3). Host-authoritative: the client sends input and action
## requests, the host simulates players, doors, NPCs and replicates. Rendering lives in
## WorldView. Auto test mode (auto_role) replays a fixed script and prints FINAL.

signal leave_requested
signal sound_emitted(kind: int, pos: Vector2)
signal shot_fired(shooter: int, from: Vector2, to: Vector2, hit_npc: bool)  ## shooter 0/1 players, 2+ NPCs
signal speech_emitted(text: String, pos: Vector2, from_npc: bool)
signal notice_emitted(text: String)
signal damaged(slot: int)

enum Act { INTERACT_DOWN, INTERACT_UP, PEEK, KICK, CAMERA, FLASH, LASER, COMMAND, TASER, SWAP, SCORE }

const SLOT_HOST := 0
const SLOT_CLIENT := 1
const PLAYER_RADIUS := 14.0
const AUTO_EVENTS := {
	"host": [[0.3, "interact", 0], [3.7, "peek", 0], [5.0, "flash", 0], [5.8, "kick", 0], [6.5, "command", 0],
			[7.0, "fire", 0], [7.5, "swap", 0], [8.0, "reload", 0]],
	"client": [[3.5, "camera", 0], [5.5, "camera", 0], [5.6, "laser", 0], [6.8, "fire", 0], [7.2, "command", 1]],
}

var auto_role := ""
var shot_path := ""

var tuning: Dictionary = {}
var level: Level
var players: Array[PlayerState] = []
var shown: Array[Vector2] = []
var director: NpcDirector
var score := 0
var is_host := false
var my_slot := 0
var running := false
var rtt_ms := -1

var _speed := 0.0
var _door_range := 0.0
var _stride_px := 60.0
var _acts: Dictionary = {}
var _lines: Dictionary = {}
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
var _voice := RandomNumberGenerator.new()


func _ready() -> void:
	tuning = JsonData.load_dict("res://data/tuning.json")
	_speed = float(tuning["move_speed"])
	_door_range = float(tuning["door_range"])
	_stride_px = float(tuning["footstep_stride_px"])
	_acts = tuning["actions"]
	_lines = JsonData.load_dict("res://data/commands.json")
	_snap_interval = 1.0 / float(Session.cfg.get("tick_hz", 20))
	_ping_interval = float(Session.cfg.get("ping_interval_s", 1.0))
	is_host = Session.is_hosting
	my_slot = SLOT_HOST if is_host else SLOT_CLIENT

	level = Level.new()
	level.name = "Level"
	add_child(level)
	level.load_map("res://data/map_01.json")
	for s in 2:
		var ps := PlayerState.new()
		ps.pos = level.spawns[s]
		players.append(ps)
		shown.append(ps.pos)
	apply_loadout(JsonData.load_dict("res://data/loadout.json"))

	var presets: Dictionary = JsonData.load_dict("res://data/difficulty.json")["presets"]
	var diff: Dictionary = presets.get(Session.difficulty, presets["normal"])
	director = NpcDirector.new(level, tuning, diff, players, 1234)
	if is_host:
		for s in 2:
			_bodies.append(_make_body(players[s].pos))
		director.sound_emitted.connect(func(kind: int, at: Vector2) -> void: _emit_sound(kind, at, true))
		director.shot.connect(_on_npc_shot)
		director.player_hit.connect(_on_player_hit)
		director.speech.connect(func(text: String, at: Vector2) -> void: _say(text, at, true))
		director.doors_changed.connect(_push_state)

	var view := WorldView.new()
	view.name = "View"
	view.world = self
	add_child(view)
	if not is_host:
		rpc_client_ready.rpc_id(1)


func apply_loadout(lo: Dictionary) -> void:
	var keys := ["host", "client"]
	for s in 2:
		var entry: Dictionary = lo[keys[s]]
		var ps := players[s]
		ps.weapons.clear()
		ps.weapon_kinds.clear()
		for kind in [str(entry["primary"]), "pistol"]:
			var st: Dictionary = tuning["weapons"][kind]
			ps.weapons.append(WeaponState.create(int(st["mag_size"]), int(st["spare_mags"]),
					float(st["fire_interval_s"]), float(st["reload_s"])))
			ps.weapon_kinds.append(kind)
		ps.tools.assign(entry["tools"])
		ps.taser_charges = int(tuning["taser_charges"]) if ps.has_tool("taser") else 0
		ps.max_hp = int(tuning["player_hp"])
		ps.hp = ps.max_hp


func display_pos(slot: int) -> Vector2:
	return players[slot].pos if is_host else shown[slot]


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


# ---- local input -----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_request_fire()
		return
	if not (event is InputEventKey) or event.echo:
		return
	if event.physical_keycode == KEY_E and not event.pressed:
		_send(Act.INTERACT_UP, 0)
	if not event.pressed:
		return
	match event.physical_keycode:
		KEY_E:
			_send(Act.PEEK if event.shift_pressed else Act.INTERACT_DOWN, 0)
		KEY_X:
			_send(Act.KICK, 0)
		KEY_C:
			_send(Act.CAMERA, 0)
		KEY_F:
			_send(Act.FLASH, 0)
		KEY_L:
			_send(Act.LASER, 0)
		KEY_T:
			_send(Act.TASER, 0)
		KEY_Q:
			_send(Act.SWAP, 0)
		KEY_R:
			_request_reload()
		KEY_F9:
			_send(Act.SCORE, 0)
		KEY_1, KEY_2, KEY_3, KEY_4:
			_send(Act.COMMAND, event.physical_keycode - KEY_1)
		KEY_ESCAPE:
			leave_requested.emit()


func _local_input() -> Dictionary:
	if auto_role != "":
		return {"move": _auto_move(), "aim": 0.0}
	var m := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var a := (get_global_mouse_position() - display_pos(my_slot)).angle()
	return {"move": m.limit_length(1.0), "aim": a}


func _send(act: int, arg: int) -> void:
	if not running:
		return
	if is_host:
		_do_act(SLOT_HOST, act, arg)
	else:
		rpc_act.rpc_id(1, act, arg)


func _request_fire() -> void:
	if not running:
		return
	if is_host:
		_host_fire(SLOT_HOST, players[SLOT_HOST].aim)
	else:
		rpc_fire.rpc_id(1, players[SLOT_CLIENT].aim)


func _request_reload() -> void:
	if not running:
		return
	if is_host:
		_host_reload(SLOT_HOST)
	else:
		rpc_reload.rpc_id(1)


# ---- frame loop -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not running:
		return
	_t += delta
	var local := _local_input()
	if not players[my_slot].dead():
		players[my_slot].aim = local.aim
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
		shown[s] = shown[s].lerp(players[s].pos, minf(delta * 15.0, 1.0))


# ---- host simulation --------------------------------------------------------

func _frozen() -> bool:
	return auto_role != "" and _t >= 9.0


func _step_host(delta: float, host_move: Vector2) -> void:
	if not _frozen():
		var moves: Array[Vector2] = [host_move, _client_move]
		for s in 2:
			var ps := players[s]
			var b := _bodies[s]
			b.velocity = moves[s] * _speed if not (ps.busy() or ps.dead()) else Vector2.ZERO
			b.move_and_slide()
			ps.pos = b.position
			_stride[s] += b.get_real_velocity().length() * delta
			if _stride[s] >= _stride_px:
				_stride[s] = 0.0
				_emit_sound(SoundProp.Kind.FOOTSTEP, ps.pos)
			for w in ps.weapons:
				if w.update(delta):
					_push_weapons()
		_step_actions(delta)
		director.tick(delta)
	_snap_accum += delta
	if _snap_accum >= _snap_interval:
		_snap_accum = 0.0
		var pk := director.pack()
		rpc_snapshot.rpc(players[0].pos, players[1].pos, players[0].aim, players[1].aim,
				players[0].pack(), players[1].pack(), pk[0], pk[1], pk[2])


func _step_actions(delta: float) -> void:
	for s in 2:
		var ps := players[s]
		ps.kick_cd = maxf(ps.kick_cd - delta, 0.0)
		if not ps.busy():
			continue
		ps.action_t += delta
		match ps.action:
			PlayerState.ACTION_CAMERA:
				if ps.action_t >= ps.action_dur:
					ps.end_action()
			PlayerState.ACTION_LOCKPICK:
				if level.nearest_door(ps.pos, _door_range) != ps.action_target:
					ps.end_action()
				elif ps.action_t >= ps.action_dur:
					level.set_locked(ps.action_target, false)
					ps.end_action()
					_push_state()
					_notice(s, tr("잠금을 풀었습니다"))
			PlayerState.ACTION_RESTRAIN:
				if director.restrain_candidate(ps.pos) != ps.action_target:
					ps.end_action()
				elif ps.action_t >= ps.action_dur:
					director.restrain(ps.action_target)
					ps.end_action()
					_notice(s, tr("구속했습니다"))


func _do_act(slot: int, act: int, arg: int) -> void:
	var ps := players[slot]
	if ps.dead():
		return
	match act:
		Act.INTERACT_DOWN:
			_interact(slot)
		Act.INTERACT_UP:
			if ps.action == PlayerState.ACTION_LOCKPICK or ps.action == PlayerState.ACTION_RESTRAIN:
				ps.end_action()
		Act.PEEK:
			_peek(slot)
		Act.KICK:
			_kick(slot)
		Act.CAMERA:
			_camera(slot)
		Act.FLASH:
			ps.flash = not ps.flash
		Act.LASER:
			ps.laser = not ps.laser
		Act.COMMAND:
			_command(slot, arg)
		Act.TASER:
			_taser(slot)
		Act.SWAP:
			if not ps.busy():
				ps.active = 1 - ps.active
				_push_weapons()
		Act.SCORE:
			score += 10
			_push_state()


func _interact(slot: int) -> void:
	var ps := players[slot]
	if ps.busy():
		return
	var npc := director.restrain_candidate(ps.pos)
	if npc >= 0:
		ps.begin_action(PlayerState.ACTION_RESTRAIN, npc, float(_acts["restrain_s"]))
		return
	var i := level.nearest_door(ps.pos, _door_range)
	if i < 0:
		return
	if level.is_locked(i) and level.get_door_state(i) == Level.DoorState.CLOSED:
		if ps.has_tool("lockpick"):
			ps.begin_action(PlayerState.ACTION_LOCKPICK, i, float(_acts["lockpick_s"]))
		else:
			_notice(slot, tr("잠겨 있습니다. 락픽이 없으면 발로 차야 합니다"))
		return
	level.toggle_door(i, slot + 1)
	_door_changed(i, SoundProp.Kind.DOOR)


func _peek(slot: int) -> void:
	var ps := players[slot]
	if ps.busy():
		return
	var i := level.nearest_door(ps.pos, _door_range)
	if i < 0:
		return
	var st := level.get_door_state(i)
	if st == Level.DoorState.CLOSED and level.is_locked(i):
		_notice(slot, tr("잠겨 있어 열 수 없습니다"))
	elif st == Level.DoorState.CLOSED:
		level.set_door_state(i, Level.DoorState.AJAR, slot + 1)
		_door_changed(i, SoundProp.Kind.DOOR_AJAR)
	elif st == Level.DoorState.AJAR:
		level.set_door_state(i, Level.DoorState.CLOSED, slot + 1)
		_door_changed(i, SoundProp.Kind.DOOR_AJAR)


func _kick(slot: int) -> void:
	var ps := players[slot]
	if ps.busy() or ps.kick_cd > 0.0:
		return
	var i := level.nearest_door(ps.pos, _door_range + 10.0)
	if i < 0 or level.get_door_state(i) == Level.DoorState.OPEN:
		return
	ps.kick_cd = float(_acts["kick_cooldown_s"])
	level.set_locked(i, false)
	level.set_door_state(i, Level.DoorState.OPEN, slot + 1)
	_door_changed(i, SoundProp.Kind.KICK)


func _camera(slot: int) -> void:
	var ps := players[slot]
	if ps.action == PlayerState.ACTION_CAMERA:
		ps.end_action()
		return
	if ps.busy() or not ps.has_tool("camera"):
		return
	var i := level.nearest_door(ps.pos, _door_range)
	if i < 0 or level.get_door_state(i) == Level.DoorState.OPEN:
		_notice(slot, tr("문틈 카메라를 쓸 닫힌 문이 가까이에 없습니다"))
		return
	ps.begin_action(PlayerState.ACTION_CAMERA, i, float(_acts["camera_s"]))


func _taser(slot: int) -> void:
	var ps := players[slot]
	if ps.busy() or not ps.has_tool("taser"):
		return
	if ps.taser_charges <= 0:
		_notice(slot, tr("테이저 충전이 없습니다"))
		return
	ps.taser_charges -= 1
	var reach := float(tuning["taser_range"])
	var to := ps.pos + Vector2.from_angle(ps.aim) * reach
	var wall := level.ray_hit(ps.pos, to)
	if not wall.is_empty():
		to = wall["position"]
	var hit := director.taser(slot, reach)
	_apply_shot(slot, ps.pos, to, hit >= 0)
	rpc_shot.rpc(slot, ps.pos, to, hit >= 0)


func _command(slot: int, cmd: int) -> void:
	if cmd < 0 or cmd >= NpcBrain.CMD_KEYS.size():
		return
	var options: Array = _lines[NpcBrain.CMD_KEYS[cmd]]
	_say(str(options[_voice.randi() % options.size()]), players[slot].pos)
	_emit_sound(SoundProp.Kind.VOICE, players[slot].pos)
	director.command(slot, cmd)


func _host_fire(slot: int, angle: float) -> void:
	var ps := players[slot]
	if ps.dead() or ps.busy() or not is_finite(angle):
		return
	if not ps.weapons[ps.active].try_fire():
		return
	var st: Dictionary = tuning["weapons"][ps.weapon_kinds[ps.active]]
	var dir := Vector2.from_angle(angle)
	var from := ps.pos + dir * 20.0
	var to := from + dir * float(st["range"])
	var wall := level.ray_hit(from, to)
	if not wall.is_empty():
		to = wall["position"]
	var res := director.resolve_player_shot(slot, from, to, int(st["damage"]), bool(st["stun"]))
	to = res["end"]
	var hit_npc := int(res["npc"]) >= 0
	_apply_shot(slot, from, to, hit_npc)
	rpc_shot.rpc(slot, from, to, hit_npc)
	_emit_sound(SoundProp.Kind.GUNSHOT, from)
	_push_weapons()


func _host_reload(slot: int) -> void:
	var ps := players[slot]
	if not ps.dead() and not ps.busy() and ps.weapons[ps.active].start_reload():
		_push_weapons()


func _door_changed(i: int, kind: int) -> void:
	_emit_sound(kind, level.door_rects[i].get_center())
	_push_state()


func _on_player_hit(slot: int, _npc: int) -> void:
	var ps := players[slot]
	ps.hp = maxi(ps.hp - 1, 0)
	if ps.busy():
		ps.end_action()
	damaged.emit(slot)
	rpc_hit.rpc(slot)
	Session.log_line("player %d hit, hp=%d" % [slot, ps.hp])


func _on_npc_shot(npc: int, from: Vector2, to: Vector2) -> void:
	_apply_shot(2 + npc, from, to, false)
	rpc_shot.rpc(2 + npc, from, to, false)


func _apply_shot(shooter: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	shot_fired.emit(shooter, from, to, hit_npc)


func _say(text: String, at: Vector2, from_npc: bool = false) -> void:
	speech_emitted.emit(text, at, from_npc)
	if running:
		rpc_speech.rpc(text, at, from_npc)


func _notice(slot: int, text: String) -> void:
	if slot == my_slot:
		notice_emitted.emit(text)
	elif running:
		rpc_notice.rpc_id(_client_id, text)


func _emit_sound(kind: int, at: Vector2, from_npc: bool = false) -> void:
	sound_emitted.emit(kind, at)
	if running:
		rpc_sound.rpc(kind, at)
	if not from_npc and is_host:
		director.on_sound(kind, at, -1)


func _push_state() -> void:
	if running:
		rpc_state.rpc(level.pack_doors(), score)


func _push_weapons() -> void:
	if running:
		rpc_weapons.rpc(_pack_weapons())


func _pack_weapons() -> Array:
	var out: Array = []
	for ps in players:
		for w in ps.weapons:
			out.append(w.to_packed())
	return out


func _from_client() -> bool:
	return is_host and running and multiplayer.get_remote_sender_id() == _client_id


# ---- RPC -------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func rpc_client_ready() -> void:
	if not is_host or running:
		return
	_client_id = multiplayer.get_remote_sender_id()
	running = true
	_t = 0.0
	Session.log_line("client ready id=%d" % _client_id)
	rpc_loadout.rpc_id(_client_id, JsonData.load_dict("res://data/loadout.json"))
	rpc_state.rpc_id(_client_id, level.pack_doors(), score)
	rpc_weapons.rpc_id(_client_id, _pack_weapons())


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_input(move: Vector2, angle: float) -> void:
	if not _from_client() or not move.is_finite() or not is_finite(angle):
		return
	_client_move = move.limit_length(1.0)
	players[SLOT_CLIENT].aim = angle


@rpc("any_peer", "call_remote", "reliable")
func rpc_act(act: int, arg: int) -> void:
	if _from_client() and act >= 0 and act <= Act.SCORE and arg >= 0 and arg <= 3:
		_do_act(SLOT_CLIENT, act, arg)


@rpc("any_peer", "call_remote", "reliable")
func rpc_fire(angle: float) -> void:
	if _from_client():
		_host_fire(SLOT_CLIENT, angle)


@rpc("any_peer", "call_remote", "reliable")
func rpc_reload() -> void:
	if _from_client():
		_host_reload(SLOT_CLIENT)


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
func rpc_loadout(lo: Dictionary) -> void:
	apply_loadout(lo)


@rpc("authority", "call_remote", "reliable")
func rpc_state(doors: PackedInt32Array, score_value: int) -> void:
	level.unpack_doors(doors)
	score = score_value
	running = true


@rpc("authority", "call_remote", "reliable")
func rpc_weapons(packed: Array) -> void:
	var n := 0
	for ps in players:
		for w in ps.weapons:
			if n < packed.size():
				w.from_packed(packed[n])
			n += 1


@rpc("authority", "call_remote", "reliable")
func rpc_shot(shooter: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	_apply_shot(shooter, from, to, hit_npc)


@rpc("authority", "call_remote", "reliable")
func rpc_sound(kind: int, at: Vector2) -> void:
	sound_emitted.emit(kind, at)


@rpc("authority", "call_remote", "reliable")
func rpc_speech(text: String, at: Vector2, from_npc: bool) -> void:
	speech_emitted.emit(text, at, from_npc)


@rpc("authority", "call_remote", "reliable")
func rpc_notice(text: String) -> void:
	notice_emitted.emit(text)


@rpc("authority", "call_remote", "reliable")
func rpc_hit(slot: int) -> void:
	damaged.emit(slot)


@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_snapshot(p0: Vector2, p1: Vector2, a0: float, a1: float, ps0: PackedInt32Array, ps1: PackedInt32Array,
		npc_pos: PackedVector2Array, npc_data: PackedInt32Array, npc_face: PackedFloat32Array) -> void:
	players[0].pos = p0
	players[1].pos = p1
	players[SLOT_HOST].aim = a0
	players[0].unpack(ps0)
	players[1].unpack(ps1)
	director.unpack(npc_pos, npc_data, npc_face)
	if not _have_snap:
		_have_snap = true
		shown[0] = p0
		shown[1] = p1
	_snap_count += 1


# ---- auto test -------------------------------------------------------------

func _auto_move() -> Vector2:
	return Vector2.RIGHT if _t >= 0.5 and _t < 3.4 else Vector2.ZERO


func _auto_tick() -> void:
	if auto_role == "":
		return
	var events: Array = AUTO_EVENTS[auto_role]
	for i in events.size():
		if _t >= events[i][0] and not _auto_done.has(i):
			_auto_done[i] = true
			_auto_do(str(events[i][1]), int(events[i][2]))
	if shot_path != "" and _t >= 6.2 and not _auto_done.has("shot"):
		_auto_done["shot"] = true
		_capture(shot_path)
	if _t >= 10.0 and not _auto_done.has("final"):
		_auto_done["final"] = true
		var npcs := PackedStringArray()
		for a in director.agents:
			npcs.append("%d/%d/%.0f,%.0f" % [a.brain.state, a.brain.hp, a.pos.x, a.pos.y])
		Session.log_line("FINAL p0=%.1f,%.1f p1=%.1f,%.1f doors=%s score=%d ps0=%s ps1=%s w=%s npcs=%s" % [
			players[0].pos.x, players[0].pos.y, players[1].pos.x, players[1].pos.y, level.pack_doors(), score,
			players[0].pack(), players[1].pack(), str(_pack_weapons()), ";".join(npcs)])
	if _t >= 10.5:
		get_tree().quit()


func _auto_do(name: String, arg: int) -> void:
	match name:
		"interact":
			_send(Act.INTERACT_DOWN, 0)
			_send(Act.INTERACT_UP, 0)
		"peek":
			_send(Act.PEEK, 0)
		"kick":
			_send(Act.KICK, 0)
		"camera":
			_send(Act.CAMERA, 0)
		"flash":
			_send(Act.FLASH, 0)
		"laser":
			_send(Act.LASER, 0)
		"command":
			_send(Act.COMMAND, arg)
		"swap":
			_send(Act.SWAP, 0)
		"fire":
			_request_fire()
		"reload":
			_request_reload()


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	Session.log_line("screenshot saved")
