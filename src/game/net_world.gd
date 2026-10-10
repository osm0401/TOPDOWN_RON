class_name NetWorld
extends Node2D
## Online gray-box world (stage 5). Host-authoritative: the client sends input and action
## requests, the host simulates players, doors, NPCs and the mission, then replicates.
## Rendering lives in WorldView / MissionPanel. Auto test mode (auto_role + scenario)
## replays a fixed script and prints FINAL.

signal leave_requested
signal sound_emitted(kind: int, pos: Vector2)
signal shot_fired(shooter: int, from: Vector2, to: Vector2, hit_npc: bool)  ## shooter 0/1 players, 2+ NPCs
signal speech_emitted(text: String, pos: Vector2, from_npc: bool)
signal notice_emitted(text: String)
signal damaged(slot: int)
signal restart_requested  ## the vote chose a retry: Main rebuilds the world
signal lobby_requested    ## the vote chose the main lobby

enum Act { INTERACT_DOWN, INTERACT_UP, PEEK, KICK, CAMERA, FLASH, LASER, COMMAND, TASER, SWAP, READY, VOTE_RETRY, VOTE_LOBBY }

const SLOT_HOST := 0
const SLOT_CLIENT := 1
const PLAYER_RADIUS := 14.0
const SCENARIOS := {
	"": {
		"events": {
			"host": [[0.1, "ready", 0], [0.3, "interact", 0], [3.7, "peek", 0], [5.0, "flash", 0], [5.8, "kick", 0],
					[6.5, "command", 0], [7.0, "fire", 0], [7.5, "swap", 0], [8.0, "reload", 0]],
			"client": [[0.1, "ready", 0], [3.5, "camera", 0], [5.5, "camera", 0], [5.6, "laser", 0], [6.8, "fire", 0],
					[7.2, "command", 1]],
		},
		"shot": 6.2, "final": 10.0,
	},
	"briefing": {
		"events": {"host": [[4.0, "ready", 0]], "client": [[4.0, "ready", 0]]},
		"shot": 2.0, "final": 5.0,
	},
	"clues": {
		"events": {"host": [[0.1, "ready", 0], [0.2, "teleport_c", 0]], "client": [[0.1, "ready", 0]]},
		"shot": 0.6, "final": 3.0,
	},
	"down": {
		"events": {"host": [[0.1, "ready", 0], [0.2, "teleport_c", 0], [0.4, "stun_suspect", 0]], "client": [[0.1, "ready", 0]]},
		"shot": 1.2, "final": 3.0,
	},
	"dark": {
		"events": {"host": [[0.1, "ready", 0], [0.2, "teleport_dark", 0]], "client": [[0.1, "ready", 0]]},
		"shot": 1.0, "final": 3.0,
	},
	"result": {
		"events": {"host": [[0.1, "ready", 0], [2.0, "kill_suspect", 0]], "client": [[0.1, "ready", 0]]},
		"shot": 3.5, "final": 5.0,
	},
	"reinforce": {
		"events": {"host": [[0.1, "ready", 0], [0.2, "clock_soon", 0]], "client": [[0.1, "ready", 0]]},
		"shot": 10.0, "final": 12.0,
	},
	# vote: host and client disagree in round 1, agree on a retry in round 2 -> both worlds restart
	"vote": {
		"events": {
			"host": [[0.1, "ready", 0], [1.0, "kill_suspect", 0], [2.5, "vote_retry", 0], [4.5, "vote_retry", 0]],
			"client": [[0.1, "ready", 0], [2.5, "vote_lobby", 0], [4.5, "vote_retry", 0]],
		},
		"shot": 3.0, "final": 8.0,
	},
}

var auto_role := ""
var scenario := ""
var generation := 0  ## how many times the mission was restarted by a vote
var shot_path := ""
var mouse_world := Callable()  ## set by a 3D view: cursor position on the 2D ground plane (px)

var tuning: Dictionary = {}
var score_rules: Dictionary = {}
var level: Level
var players: Array[PlayerState] = []
var shown: Array[Vector2] = []
var director: NpcDirector
var mission := MissionState.new()
var clock: ReinforcementClock
var vote: VoteState
var is_host := false
var solo := false
var my_slot := 0
var running := false
var rtt_ms := -1

var _speed := 0.0
var _door_range := 0.0
var _stride_px := 60.0
var _acts: Dictionary = {}
var _lines: Dictionary = {}
var _rcfg: Dictionary = {}
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
	score_rules = JsonData.load_dict("res://data/score.json")
	_speed = float(tuning["move_speed"])
	_door_range = float(tuning["door_range"])
	_stride_px = float(tuning["footstep_stride_px"])
	_acts = tuning["actions"]
	_lines = JsonData.load_dict("res://data/commands.json")
	_snap_interval = 1.0 / float(Session.cfg.get("tick_hz", 20))
	_ping_interval = float(Session.cfg.get("ping_interval_s", 1.0))
	is_host = Session.is_hosting
	solo = Session.solo
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
	var lo := JsonData.load_dict("res://data/loadout.json")
	if solo:
		lo["host"] = Session.solo_loadout
	apply_loadout(lo)
	if solo:
		players[SLOT_CLIENT].present = false
		players[SLOT_CLIENT].hp = 0
		running = true
		mission.mark_ready(SLOT_CLIENT)

	var presets: Dictionary = JsonData.load_dict("res://data/difficulty.json")["presets"]
	var diff: Dictionary = presets.get(Session.difficulty, presets["normal"])
	director = NpcDirector.new(level, tuning, diff, players, 1234)
	_rcfg = tuning["reinforcement"]
	clock = ReinforcementClock.new(float(diff["reinforce_s"]), float(_rcfg["min_warning_s"]), float(_rcfg["min_lead_after_noise_s"]))
	vote = VoteState.new(float(tuning["vote"]["round_s"]), int(tuning["vote"]["max_rounds"]))
	if is_host:
		for s in 2:
			_bodies.append(_make_body(players[s].pos))
		director.sound_emitted.connect(func(kind: int, at: Vector2) -> void: _emit_sound(kind, at, true))
		director.shot.connect(_on_npc_shot)
		director.player_hit.connect(_on_player_hit)
		director.speech.connect(func(text: String, at: Vector2) -> void: _say(text, at, true))
		director.doors_changed.connect(_push_state)
		director.npc_killed.connect(_on_npc_killed)

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


func score_counts() -> Dictionary:
	var dead := 0
	for ps in players:
		if ps.present and ps.dead():
			dead += 1
	return ScoreRules.counts(mission, dead)


func current_score() -> int:
	return ScoreRules.compute(score_counts(), score_rules)


## True when there is a peer to talk to (never in single player).
func _online() -> bool:
	return running and not solo


func _active() -> bool:
	return mission.phase == MissionState.Phase.ACTIVE


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
		KEY_ENTER, KEY_KP_ENTER:
			_send(Act.READY, 0)
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
		KEY_1, KEY_2, KEY_3, KEY_4:
			var n: int = event.physical_keycode - KEY_1
			if mission.phase == MissionState.Phase.RESULT:
				if n == 0:
					_send(Act.VOTE_RETRY, 0)
				elif n == 1:
					_send(Act.VOTE_LOBBY, 0)
			else:
				_send(Act.COMMAND, n)
		KEY_ESCAPE:
			leave_requested.emit()


func _local_input() -> Dictionary:
	if auto_role != "":
		return {"move": _auto_move(), "aim": 0.0}
	var m := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var mouse: Vector2 = mouse_world.call() if mouse_world.is_valid() else get_global_mouse_position()
	var a := (mouse - display_pos(my_slot)).angle()
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
	if not is_host and mission.phase == MissionState.Phase.RESULT and vote.outcome == VoteState.Outcome.PENDING:
		vote.time_left = maxf(vote.time_left - delta, 0.0)  # display only, the host decides


# ---- host simulation --------------------------------------------------------

func _frozen() -> bool:
	return auto_role != "" and _t >= float(SCENARIOS[scenario]["final"]) - 1.0


func _step_host(delta: float, host_move: Vector2) -> void:
	if _active() and not _frozen():
		var moves: Array[Vector2] = [host_move, _client_move]
		for s in 2:
			var ps := players[s]
			if not ps.present:
				continue
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
		_update_reinforcements(delta)
		_update_mission()
	elif mission.phase == MissionState.Phase.RESULT:
		_update_vote(delta)
	_snap_accum += delta
	if _online() and _snap_accum >= _snap_interval:
		_snap_accum = 0.0
		var pk := director.pack()
		rpc_snapshot.rpc(players[0].pos, players[1].pos, players[0].aim, players[1].aim,
				players[0].pack(), players[1].pack(), pk[0], pk[1], pk[2])


## Objective and failure bookkeeping, evaluated by the pure MissionState rules.
func _update_mission() -> void:
	var snap := {
		"suspect_restrained": false, "suspect_dead": false, "civ_unrestrained_alive": 0,
		"enemies_pending": 0, "players_alive": 0, "players_in_exit": 0,
	}
	for a in director.agents:
		if a.dormant:
			continue  # reinforcements that have not arrived are no threat yet
		var st := a.brain.state
		var settled := st == NpcBrain.State.DEAD or st == NpcBrain.State.RESTRAINED
		if a.suspect:
			snap["suspect_restrained"] = st == NpcBrain.State.RESTRAINED
			snap["suspect_dead"] = st == NpcBrain.State.DEAD
		elif a.brain.role == NpcBrain.Role.CIVILIAN:
			snap["civ_unrestrained_alive"] += 0 if settled else 1
		else:
			snap["enemies_pending"] += 0 if settled else 1
	for ps in players:
		if not ps.dead():
			snap["players_alive"] += 1
			if level.exit_zone.has_point(ps.pos):
				snap["players_in_exit"] += 1
	if mission.evaluate(snap):
		_push_mission()
		if mission.phase == MissionState.Phase.RESULT:
			Session.log_line("MISSION %s reason=%s score=%d grade=%s" % [
				"success" if mission.status == MissionState.Status.SUCCESS else "failed", mission.reason_key(),
				current_score(), ScoreRules.grade(current_score(), score_rules)])
			var present: Array[bool] = [true, not solo]
			vote.start(present, not solo)
			_push_vote()


## Reinforcement clock: warning (radio + siren) first, arrival later. Loud noise and enemies
## that have noticed the players speed it up (noise is added in _emit_sound).
func _update_reinforcements(delta: float) -> void:
	var mult := 1.0
	for a in director.agents:
		if not a.dormant and a.brain.role == NpcBrain.Role.ENEMY and a.brain.is_alert():
			mult = float(_rcfg["alarm_mult"])
			break
	var event := clock.tick(delta * mult)
	if event == "warning":
		mission.reinforce = ReinforcementClock.Phase.WARNED
		_push_mission()
		_notice_all(tr("무전: 외부에서 지원 병력이 접근 중이다!"))
		_emit_sound(SoundProp.Kind.SIREN, _vec2(_rcfg["siren_at"]))
		Session.log_line("reinforcement warning")
	elif event == "arrive":
		mission.reinforce = ReinforcementClock.Phase.ARRIVED
		director.activate_reinforcements(_vec2(_rcfg["target"]))
		_push_mission()
		_notice_all(tr("증원이 도착했다! 입구 쪽을 조심하라"))
		Session.log_line("reinforcement arrived")


func _update_vote(delta: float) -> void:
	if vote.outcome == VoteState.Outcome.PENDING and vote.tick(delta):
		_push_vote()
		_check_vote_outcome()


func _check_vote_outcome() -> void:
	match vote.outcome:
		VoteState.Outcome.RETRY:
			Session.log_line("vote: retry")
			if _online():
				rpc_restart.rpc()
			restart_requested.emit()
		VoteState.Outcome.LOBBY:
			Session.log_line("vote: lobby")
			if _online():
				rpc_to_lobby.rpc()
			lobby_requested.emit()


static func _vec2(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


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
	if act == Act.READY:
		if mission.mark_ready(slot):
			_push_mission()
		return
	if act == Act.VOTE_RETRY or act == Act.VOTE_LOBBY:
		var choice := VoteState.Choice.RETRY if act == Act.VOTE_RETRY else VoteState.Choice.LOBBY
		if mission.phase == MissionState.Phase.RESULT and vote.cast(slot, choice):
			_push_vote()
			_check_vote_outcome()
		return
	if ps.dead() or not _active():
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
	if _online():
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
	if ps.dead() or ps.busy() or not _active() or not is_finite(angle):
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
	if _online():
		rpc_shot.rpc(slot, from, to, hit_npc)
	_emit_sound(SoundProp.Kind.GUNSHOT, from)
	_push_weapons()


func _host_reload(slot: int) -> void:
	var ps := players[slot]
	if not ps.dead() and not ps.busy() and _active() and ps.weapons[ps.active].start_reload():
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
	if _online():
		rpc_hit.rpc(slot)
	Session.log_line("player %d hit, hp=%d" % [slot, ps.hp])


func _on_npc_killed(npc: int, _slot: int) -> void:
	var a: NpcDirector.Agent = director.agents[npc]
	if a.suspect:
		mission.suspect_killed += 1
	elif a.brain.role == NpcBrain.Role.CIVILIAN:
		mission.civ_killed += 1
	else:
		mission.enemy_killed += 1
	Session.log_line("npc %d killed (suspect=%s role=%d)" % [npc, a.suspect, a.brain.role])
	_push_mission()


func _on_npc_shot(npc: int, from: Vector2, to: Vector2) -> void:
	_apply_shot(2 + npc, from, to, false)
	if _online():
		rpc_shot.rpc(2 + npc, from, to, false)


func _apply_shot(shooter: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	shot_fired.emit(shooter, from, to, hit_npc)


func _say(text: String, at: Vector2, from_npc: bool = false) -> void:
	speech_emitted.emit(text, at, from_npc)
	if _online():
		rpc_speech.rpc(text, at, from_npc)


func _notice(slot: int, text: String) -> void:
	if slot == my_slot:
		notice_emitted.emit(text)
	elif _online():
		rpc_notice.rpc_id(_client_id, text)


func _notice_all(text: String) -> void:
	notice_emitted.emit(text)
	if _online():
		rpc_notice.rpc(text)


func _emit_sound(kind: int, at: Vector2, from_npc: bool = false) -> void:
	sound_emitted.emit(kind, at)
	if _online():
		rpc_sound.rpc(kind, at)
	if is_host and kind != SoundProp.Kind.SIREN:
		if not from_npc:
			director.on_sound(kind, at, -1)
		if _active():
			clock.add_noise(float(_rcfg["noise_s"].get(SoundProp.NAMES[kind], 0.0)))


func _push_state() -> void:
	if _online():
		rpc_state.rpc(level.pack_doors())


func _push_mission() -> void:
	if _online():
		rpc_mission.rpc(mission.pack())


func _push_vote() -> void:
	if _online():
		rpc_vote.rpc(vote.pack())


func _push_weapons() -> void:
	if _online():
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
	rpc_state.rpc_id(_client_id, level.pack_doors())
	rpc_weapons.rpc_id(_client_id, _pack_weapons())
	rpc_mission.rpc_id(_client_id, mission.pack())
	rpc_vote.rpc_id(_client_id, vote.pack())


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_input(move: Vector2, angle: float) -> void:
	if not _from_client() or not move.is_finite() or not is_finite(angle):
		return
	_client_move = move.limit_length(1.0)
	players[SLOT_CLIENT].aim = angle


@rpc("any_peer", "call_remote", "reliable")
func rpc_act(act: int, arg: int) -> void:
	if _from_client() and act >= 0 and act <= Act.VOTE_LOBBY and arg >= 0 and arg <= 3:
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
func rpc_state(doors: PackedInt32Array) -> void:
	level.unpack_doors(doors)
	running = true


@rpc("authority", "call_remote", "reliable")
func rpc_mission(data: PackedInt32Array) -> void:
	mission.unpack(data)


@rpc("authority", "call_remote", "reliable")
func rpc_vote(data: PackedInt32Array) -> void:
	vote.unpack(data)


@rpc("authority", "call_remote", "reliable")
func rpc_restart() -> void:
	restart_requested.emit()


@rpc("authority", "call_remote", "reliable")
func rpc_to_lobby() -> void:
	lobby_requested.emit()


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
	if scenario != "":
		return Vector2.ZERO
	return Vector2.RIGHT if _t >= 0.5 and _t < 3.4 else Vector2.ZERO


func _auto_tick() -> void:
	if auto_role == "":
		return
	var scn: Dictionary = SCENARIOS[scenario]
	var events: Array = scn["events"][auto_role] if generation == 0 else []
	var final_t := float(scn["final"]) if generation == 0 else 1.0
	for i in events.size():
		if _t >= events[i][0] and not _auto_done.has(i):
			_auto_done[i] = true
			_auto_do(str(events[i][1]), int(events[i][2]))
	if shot_path != "" and generation == 0 and _t >= float(scn["shot"]) and not _auto_done.has("shot"):
		_auto_done["shot"] = true
		_capture(shot_path)
	if _t >= final_t and not _auto_done.has("final"):
		_auto_done["final"] = true
		var npcs := PackedStringArray()
		for a in director.agents:
			npcs.append("%d/%d/%.0f,%.0f" % [a.brain.state, a.brain.hp, a.pos.x, a.pos.y])
		Session.log_line("FINAL p0=%.1f,%.1f p1=%.1f,%.1f doors=%s ps0=%s ps1=%s w=%s npcs=%s mission=%s score=%d gen=%d" % [
			players[0].pos.x, players[0].pos.y, players[1].pos.x, players[1].pos.y, level.pack_doors(),
			players[0].pack(), players[1].pack(), str(_pack_weapons()), ";".join(npcs), mission.pack(), current_score(), generation])
	if _t >= final_t + 0.5:
		get_tree().quit()


func _auto_do(name: String, arg: int) -> void:
	match name:
		"ready":
			_send(Act.READY, 0)
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
		"teleport_c":  # test aid: put the host inside room C to look at the suspect and the decoys
			_bodies[0].position = Vector2(1100, 340)
			players[0].pos = Vector2(1100, 340)
			players[0].aim = 0.0
		"teleport_dark":  # test aid: put the host inside dark room B to look at the darkness cues
			_bodies[0].position = Vector2(700, 330)
			players[0].pos = Vector2(700, 330)
			players[0].aim = 0.0
		"vote_retry":
			_send(Act.VOTE_RETRY, 0)
		"vote_lobby":
			_send(Act.VOTE_LOBBY, 0)
		"clock_soon":  # test aid: reinforcements in ~10 s instead of minutes
			clock.remaining = 9.5
		"stun_suspect":  # test aid: a non-lethal round knocks the suspect down (alive, wakes up later)
			for a in director.agents:
				if a.suspect:
					director.resolve_player_shot(0, a.pos + Vector2(-60, 0), a.pos + Vector2(60, 0), 0, true)
		"kill_suspect":
			for a in director.agents:
				if a.suspect:
					director.resolve_player_shot(0, a.pos + Vector2(-60, 0), a.pos + Vector2(60, 0), 99, false)


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	Session.log_line("screenshot saved")
