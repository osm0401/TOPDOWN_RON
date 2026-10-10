extends Node
## Offline integration test of the host-side NetWorld logic (doors, tools, commands,
## restraint, taser, camera). Runs in the real main loop so the Session autoload exists:
##   Godot_console.exe --headless --path D:\TOPDOWNRON res://tests/world_test.tscn
## Exit code 0 = all passed.

var _failed := 0
var _w: NetWorld


func _ready() -> void:
	Engine.time_scale = 2.0
	Session.host(true)
	await _boot(true)
	await _run()
	await _mission_tests()
	await _solo_tests()
	await _stage5_tests()
	await _view3d_tests()
	print("---- %s" % ("FAILED: %d" % _failed if _failed > 0 else "ALL PASSED"))
	Engine.time_scale = 1.0
	Session.leave()
	get_tree().quit(1 if _failed > 0 else 0)


## Fresh host-side world; `ready_up` skips the briefing.
func _boot(ready_up: bool) -> void:
	if _w != null:
		remove_child(_w)
		_w.free()
	_w = NetWorld.new()
	_w.name = "World"
	add_child(_w)
	await _frames(4)
	_w.running = true
	if ready_up:
		_w.mission.mark_ready(0)
		_w.mission.mark_ready(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failed += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await _frames(int(s * 60.0 / Engine.time_scale))


## Teleports a player (body + state).
func _place(slot: int, at: Vector2, aim: float = 0.0) -> void:
	_w._bodies[slot].position = at
	_w.players[slot].pos = at
	_w.players[slot].aim = aim


func _aim(slot: int, angle: float) -> void:
	_w.players[slot].aim = angle


func _park(slot: int) -> void:
	_place(slot, Vector2(60, 520))


func _agent(i: int) -> NpcDirector.Agent:
	return _w.director.agents[i]


func _freeze_ai() -> void:
	# keep NPCs where the test put them
	for a in _w.director.agents:
		a.home = a.pos


func _run() -> void:
	var S := NpcBrain.State
	var Act := NetWorld.Act
	var lv := _w.level
	_park(0)
	_park(1)
	await _frames(3)

	# --- locked door: no lockpick -> notice, lockpick -> unlocked after the timer
	var notices := []
	_w.notice_emitted.connect(func(t: String) -> void: notices.append(t))
	_place(0, Vector2(1200, 480))
	_place(1, Vector2(1220, 485))
	await _frames(3)
	_w._do_act(0, Act.INTERACT_DOWN, 0)
	_check(notices.size() == 1 and lv.is_locked(2), "host without lockpick: told the door is locked")
	_w._do_act(1, Act.INTERACT_DOWN, 0)
	_check(_w.players[1].action == PlayerState.ACTION_LOCKPICK, "lockpick starts")
	var before := _w.players[1].pos
	await _seconds(1.0)
	_check(_w.players[1].pos.distance_to(before) < 2.0, "lockpicking player cannot move")
	_w._do_act(1, Act.INTERACT_UP, 0)
	_check(_w.players[1].action == PlayerState.ACTION_NONE and lv.is_locked(2), "releasing cancels the lockpick")
	_w._do_act(1, Act.INTERACT_DOWN, 0)
	await _seconds(3.3)
	_check(not lv.is_locked(2) and lv.get_door_state(2) == Level.DoorState.CLOSED, "lockpick finishes: unlocked, still closed")
	_w._do_act(0, Act.INTERACT_DOWN, 0)
	_w._do_act(0, Act.INTERACT_UP, 0)
	_check(lv.get_door_state(2) == Level.DoorState.OPEN and lv.door_actor[2] == 1, "now the door opens normally (actor = host)")

	# --- peek and kick
	_place(0, Vector2(1100, 530))
	_place(1, Vector2(1100, 500))
	await _frames(3)
	_w._do_act(0, Act.PEEK, 0)
	_check(lv.get_door_state(4) == Level.DoorState.AJAR, "peek: door ajar")
	_w._do_act(0, Act.PEEK, 0)
	_check(lv.get_door_state(4) == Level.DoorState.CLOSED, "peek again: closed")
	_place(0, Vector2(520, 530))
	await _frames(3)
	_w._do_act(0, Act.KICK, 0)
	_check(lv.get_door_state(3) == Level.DoorState.OPEN and not lv.is_locked(3), "kick breaks a locked door open")
	_check(_w.players[0].kick_cd > 0.0, "kick has a cooldown")

	# --- door camera
	_place(1, Vector2(820, 485))
	await _frames(3)
	_w._do_act(1, Act.CAMERA, 0)
	_check(_w.players[1].action == PlayerState.ACTION_CAMERA and _w.players[1].cam_door == 1, "door camera starts on door B")
	var cam := lv.door_cam_origin(1, _w.players[1].pos)
	_check(cam.y < 430.0, "camera sits inside room B")
	_w._do_act(1, Act.CAMERA, 0)
	_check(_w.players[1].cam_door == -1, "camera toggles off")

	# --- command -> surrender -> restraint (civilian A at 400,300)
	_park(1)
	_place(0, Vector2(400, 400), -PI / 2.0)
	_freeze_ai()
	var civ := _agent(2)
	var tries := 0
	while civ.brain.state != S.SURRENDER and civ.brain.state != S.DOWN and tries < 30:
		civ.brain.state = S.IDLE
		_aim(0, -PI / 2.0)
		_w._do_act(0, Act.COMMAND, 3)
		tries += 1
	_check(civ.brain.state == S.SURRENDER or civ.brain.state == S.DOWN, "command makes the civilian comply")
	_place(0, Vector2(400, 340), -PI / 2.0)
	await _frames(2)
	_w._do_act(0, Act.INTERACT_DOWN, 0)
	_check(_w.players[0].action == PlayerState.ACTION_RESTRAIN, "interact next to a kneeling civilian starts restraint")
	await _seconds(2.8)
	_check(civ.brain.state == S.RESTRAINED and _w.players[0].action == PlayerState.ACTION_NONE, "restraint completes")

	# --- taser: stun, disarm, restrain an enemy
	var enemy := _agent(0)
	enemy.pos = Vector2(800, 300)
	enemy.brain.pos = enemy.pos
	enemy.brain.state = S.IDLE
	_place(0, Vector2(720, 300), 0.0)
	await _frames(2)
	_check(_w.players[0].taser_charges == 2, "host starts with 2 taser charges")
	_aim(0, 0.0)
	_w._do_act(0, Act.TASER, 0)
	_check(enemy.brain.state == S.DOWN and not enemy.brain.armed, "taser: enemy down and disarmed")
	_check(_w.players[0].taser_charges == 1, "taser uses a charge")
	_place(0, Vector2(770, 300), 0.0)
	await _frames(2)
	_w._do_act(0, Act.INTERACT_DOWN, 0)
	_check(_w.players[0].action == PlayerState.ACTION_RESTRAIN, "stunned enemy can be restrained")
	await _seconds(2.8)
	_check(enemy.brain.state == S.RESTRAINED, "enemy restrained")

	# --- weapons: swap, fire
	_place(0, Vector2(600, 500), 0.0)
	await _frames(2)
	var primary := _w.players[0].weapons[0]
	_w._request_fire()
	_check(primary.current == 29, "rifle round spent")
	_w._do_act(0, Act.SWAP, 0)
	_check(_w.players[0].active == 1, "swap to the pistol")
	_w._do_act(0, Act.SWAP, 0)

	# --- damage and death stop actions
	var dmg := []
	_w.damaged.connect(func(s: int) -> void: dmg.append(s))
	_w._on_player_hit(1, 0)
	_check(_w.players[1].hp == 4 and dmg == [1], "player hit: hp down, signal sent")
	for i in 5:
		_w._on_player_hit(1, 0)
	_check(_w.players[1].dead() and _w.players[1].hp == 0, "hp never goes below zero; player dies")
	_w._do_act(1, Act.FLASH, 0)
	_check(not _w.players[1].flash, "dead players cannot act")

	# --- sound reaches NPCs through the director
	var enemy2 := _agent(1)
	enemy2.pos = Vector2(1100, 700)
	enemy2.home = enemy2.pos
	enemy2.brain.state = S.IDLE
	_w._emit_sound(SoundProp.Kind.KICK, Vector2(1100, 600))
	await _frames(3)
	_check(enemy2.brain.state == S.INVESTIGATE, "a kick next door sends the enemy to investigate")


func _mission_tests() -> void:
	var S := NpcBrain.State
	var Act := NetWorld.Act

	# briefing blocks actions until both players are ready
	await _boot(false)
	_check(_w.mission.phase == MissionState.Phase.BRIEFING, "world starts in the briefing")
	var rifle := _w.players[0].weapons[0]
	_w._request_fire()
	_w._do_act(0, Act.FLASH, 0)
	_check(rifle.current == 30 and not _w.players[0].flash, "briefing: no shooting, no actions")
	_w._do_act(0, Act.READY, 0)
	_check(_w.mission.phase == MissionState.Phase.BRIEFING, "one ready: still briefing")
	_w._do_act(1, Act.READY, 0)
	_check(_w.mission.phase == MissionState.Phase.ACTIVE, "both ready: mission starts")
	_w._do_act(0, Act.FLASH, 0)
	_check(_w.players[0].flash, "actions work once active")

	# success: everything settled, then everyone back in the exit zone
	await _boot(true)
	for a in _w.director.agents:
		if a.suspect or a.brain.role == NpcBrain.Role.CIVILIAN:
			a.brain.state = S.RESTRAINED
		else:
			a.brain.state = S.DEAD
	_place(0, Vector2(600, 500))
	_place(1, Vector2(620, 500))
	await _frames(4)
	_check(_w.mission.objectives[0] and _w.mission.objectives[1] and _w.mission.objectives[2], "first three objectives complete")
	_check(not _w.mission.objectives[3] and _w.mission.phase == MissionState.Phase.ACTIVE, "not done until they return")
	_place(0, Vector2(60, 480))
	await _frames(4)
	_check(_w.mission.phase == MissionState.Phase.ACTIVE, "one player outside is not enough")
	_place(1, Vector2(60, 520))
	await _frames(4)
	_check(_w.mission.status == MissionState.Status.SUCCESS and _w.mission.phase == MissionState.Phase.RESULT, "both back at the exit: success")
	_check(_w.current_score() == 100 and ScoreRules.grade(_w.current_score(), _w.score_rules) == "A", "clean success scores 100 / A")
	var spent := _w.players[0].weapons[0].current
	_w._request_fire()
	_check(_w.players[0].weapons[0].current == spent, "no shooting after the result")

	# failure: the suspect is shot dead
	await _boot(true)
	var suspect: NpcDirector.Agent
	for a in _w.director.agents:
		if a.suspect:
			suspect = a
	_place(0, Vector2(1100, 300))
	await _frames(2)
	_w.director.resolve_player_shot(0, Vector2(1100, 300), Vector2(1300, 300), 99, false)
	await _frames(4)
	_check(suspect.brain.state == S.DEAD and _w.mission.suspect_killed == 1, "suspect shot dead and counted")
	_check(_w.mission.status == MissionState.Status.FAILED and _w.mission.reason_key() == "suspect_killed", "mission failed: suspect killed")
	_check(_w.current_score() == 40 and ScoreRules.grade(40, _w.score_rules) == "E", "failure keeps its own score and grade (40 / E)")

	# failure: both players dead
	await _boot(true)
	for i in 5:
		_w._on_player_hit(0, 0)
		_w._on_player_hit(1, 0)
	await _frames(4)
	_check(_w.mission.status == MissionState.Status.FAILED and _w.mission.reason_key() == "all_dead", "mission failed: both players dead")
	_check(_w.current_score() == 100, "player deaths do not cost score (open value 0)")

	# a civilian killed: score only
	await _boot(true)
	var civ: NpcDirector.Agent = _w.director.agents[2]
	_place(0, Vector2(400, 400))
	await _frames(2)
	_w.director.resolve_player_shot(0, Vector2(400, 400), Vector2(400, 200), 2, false)
	await _frames(4)
	_check(civ.brain.state == S.DEAD and _w.mission.civ_killed == 1, "civilian killed and counted")
	_check(_w.mission.status == MissionState.Status.ACTIVE and _w.current_score() == 70, "civilian death: score only, mission continues")
	for a in _w.director.agents:
		if a.suspect:
			a.brain.state = S.RESTRAINED
		elif a.brain.role == NpcBrain.Role.ENEMY:
			a.brain.state = S.DEAD
	_w.director.agents[3].brain.state = S.RESTRAINED
	_place(0, Vector2(60, 480))
	_place(1, Vector2(60, 520))
	await _frames(4)
	_check(_w.mission.status == MissionState.Status.SUCCESS and _w.current_score() == 70, "dead civilians do not block the objective: success with 70 points")


func _solo_tests() -> void:
	var S := NpcBrain.State
	Session.start_solo()
	await _boot(false)
	_check(_w.solo and _w.running and _w.is_host, "solo world runs without any peer")
	_check(not _w.players[1].present and _w.players[1].dead(), "the second officer does not exist")
	_check(_w.mission.phase == MissionState.Phase.BRIEFING, "solo starts in the briefing")
	_w._do_act(0, NetWorld.Act.READY, 0)
	_check(_w.mission.phase == MissionState.Phase.ACTIVE, "only the player has to get ready")
	var me := _w.players[0]
	_check(me.has_tool("lockpick") and me.has_tool("taser") and me.weapon_kinds[0] == "rifle_nonlethal", "solo loadout from the lobby selection is used")
	_check(int(_w.score_counts()["player_dead"]) == 0, "the absent officer is not counted as dead")
	var before := _w.players[1].pos
	await _seconds(0.5)
	_check(_w.players[1].pos == before, "the absent officer never moves")

	# a solo player can lockpick the suspect's room
	_place(0, Vector2(1200, 480))
	await _frames(3)
	_w._do_act(0, NetWorld.Act.INTERACT_DOWN, 0)
	_check(me.action == PlayerState.ACTION_LOCKPICK, "solo player lockpicks the locked door")
	_w._do_act(0, NetWorld.Act.INTERACT_UP, 0)

	# success needs only the one officer back at the exit
	for a in _w.director.agents:
		if a.suspect or a.brain.role == NpcBrain.Role.CIVILIAN:
			a.brain.state = S.RESTRAINED
		else:
			a.brain.state = S.DEAD
	_place(0, Vector2(60, 500))
	await _frames(4)
	_check(_w.mission.status == MissionState.Status.SUCCESS and _w.mission.phase == MissionState.Phase.RESULT, "solo success: the lone officer back at the exit")

	# failure when the one officer dies
	await _boot(false)
	_w._do_act(0, NetWorld.Act.READY, 0)
	for i in 5:
		_w._on_player_hit(0, 0)
	await _frames(4)
	_check(_w.mission.status == MissionState.Status.FAILED and _w.mission.reason_key() == "all_dead", "solo failure when the officer dies")

	Session.leave()
	_check(not Session.solo and not Session.is_hosting, "leaving resets solo mode")


func _settle_npcs(except_reinforcements: bool = true) -> void:
	# put every non-reinforcement NPC into a finished state so only the return remains
	for a in _w.director.agents:
		if a.dormant:
			continue
		if a.suspect or a.brain.role == NpcBrain.Role.CIVILIAN:
			a.brain.state = NpcBrain.State.RESTRAINED
		else:
			a.brain.state = NpcBrain.State.DEAD


func _stage5_tests() -> void:
	var S := NpcBrain.State
	var Act := NetWorld.Act
	Session.host(true)  # the solo tests left the session; the host-side worlds below need it

	# --- noise pulls the reinforcement earlier, but only while the mission is running
	await _boot(false)
	_w.clock.remaining = 100.0
	_w._emit_sound(SoundProp.Kind.KICK, Vector2(500, 500))
	_check(is_equal_approx(_w.clock.remaining, 100.0), "briefing: noise does not move the clock")
	_w._do_act(0, Act.READY, 0)
	_w._do_act(1, Act.READY, 0)
	_w._emit_sound(SoundProp.Kind.KICK, Vector2(500, 500))
	_check(is_equal_approx(_w.clock.remaining, 92.0), "a kick makes the reinforcement 8 s sooner")
	_w._emit_sound(SoundProp.Kind.GUNSHOT, Vector2(500, 500))
	_check(is_equal_approx(_w.clock.remaining, 88.0), "a gunshot makes it 4 s sooner")
	_w._emit_sound(SoundProp.Kind.FOOTSTEP, Vector2(500, 500))
	_w._emit_sound(SoundProp.Kind.SIREN, Vector2(30, 500))
	_check(is_equal_approx(_w.clock.remaining, 88.0), "footsteps and the siren itself add nothing")

	# --- an enemy that noticed the players runs the clock faster (alarm)
	_w.clock.remaining = 100.0
	for a in _w.director.agents:
		a.home = a.pos
	_place(0, Vector2(60, 480))
	_place(1, Vector2(60, 520))
	_w.director.agents[0].brain.state = S.ATTACK
	var before := _w.clock.remaining
	await _seconds(1.0)
	_check(before - _w.clock.remaining >= 1.6, "alarm: the clock runs about twice as fast (%.2f s used)" % (before - _w.clock.remaining))

	# --- warning first (radio + siren), then arrival; reinforcements become real threats
	await _boot(true)
	_settle_npcs()
	var notices := []
	var sirens := []
	_w.notice_emitted.connect(func(t: String) -> void: notices.append(t))
	_w.sound_emitted.connect(func(kind: int, _at: Vector2) -> void:
		if kind == SoundProp.Kind.SIREN:
			sirens.append(kind))
	_place(0, Vector2(600, 500))
	_place(1, Vector2(620, 500))
	_w.clock.remaining = 9.5
	await _seconds(2.0)
	_check(_w.mission.reinforce == ReinforcementClock.Phase.WARNED and notices.size() == 1 and sirens.size() == 1, "radio warning + siren come first")
	var dormant_left := 0
	for a in _w.director.agents:
		if a.dormant:
			dormant_left += 1
	_check(dormant_left == 2, "nobody has arrived yet when the warning sounds")
	await _seconds(9.0)
	_check(_w.mission.reinforce == ReinforcementClock.Phase.ARRIVED and notices.size() == 2, "the wave arrives after the warning")
	dormant_left = 0
	for a in _w.director.agents:
		if a.dormant:
			dormant_left += 1
	_check(dormant_left == 0, "both reinforcements are in the map")

	# --- they must be dealt with before the return counts
	_place(0, Vector2(60, 480))
	_place(1, Vector2(60, 520))
	await _frames(6)
	_check(_w.mission.phase == MissionState.Phase.ACTIVE and not _w.mission.objectives[2], "arrived enemies block the mission: threats remain")
	for a in _w.director.agents:
		if a.brain.role == NpcBrain.Role.ENEMY and a.brain.state != S.RESTRAINED:
			a.brain.state = S.DEAD
	await _frames(6)
	_check(_w.mission.status == MissionState.Status.SUCCESS, "after handling them, the return completes the mission")

	# --- escaping before the wave arrives is a plain success
	await _boot(true)
	_settle_npcs()
	_w.clock.remaining = 200.0
	_place(0, Vector2(60, 480))
	_place(1, Vector2(60, 520))
	await _frames(6)
	_check(_w.mission.status == MissionState.Status.SUCCESS and _w.mission.reinforce == ReinforcementClock.Phase.WAITING, "escape before the wave: success, no reinforcements")

	# --- result vote: disagree, revote, retry
	await _boot(true)
	var restarts := []
	var lobbies := []
	_w.restart_requested.connect(func() -> void: restarts.append(1))
	_w.lobby_requested.connect(func() -> void: lobbies.append(1))
	_w._do_act(0, Act.VOTE_RETRY, 0)
	_check(_w.vote.votes[0] == 0, "no voting before the result screen")
	var suspect: NpcDirector.Agent
	for a in _w.director.agents:
		if a.suspect:
			suspect = a
	_w.director.resolve_player_shot(0, suspect.pos + Vector2(-60, 0), suspect.pos + Vector2(60, 0), 99, false)
	await _frames(4)
	_check(_w.mission.phase == MissionState.Phase.RESULT and _w.vote.outcome == VoteState.Outcome.PENDING and _w.vote.timed, "result screen starts a timed vote")
	_w._do_act(0, Act.VOTE_RETRY, 0)
	_w._do_act(1, Act.VOTE_LOBBY, 0)
	_check(_w.vote.round_no == 2 and restarts.is_empty() and lobbies.is_empty(), "disagreement -> second round, nothing happens yet")
	_w._do_act(0, Act.VOTE_RETRY, 0)
	_w._do_act(1, Act.VOTE_RETRY, 0)
	_check(restarts.size() == 1 and lobbies.is_empty(), "both retry in round 2 -> restart requested once")

	# --- still different after the second round: lobby
	await _boot(true)
	restarts.clear()
	lobbies.clear()
	_w.restart_requested.connect(func() -> void: restarts.append(1))
	_w.lobby_requested.connect(func() -> void: lobbies.append(1))
	_w.director.resolve_player_shot(0, suspect.pos + Vector2(-60, 0), suspect.pos + Vector2(60, 0), 99, false)
	for a in _w.director.agents:
		if a.suspect:
			_w.director.resolve_player_shot(0, a.pos + Vector2(-60, 0), a.pos + Vector2(60, 0), 99, false)
	await _frames(4)
	_w._do_act(0, Act.VOTE_RETRY, 0)
	_w._do_act(1, Act.VOTE_LOBBY, 0)
	_w._do_act(0, Act.VOTE_LOBBY, 0)
	_w._do_act(1, Act.VOTE_RETRY, 0)
	_check(lobbies.size() == 1 and restarts.is_empty(), "no agreement after the extra round -> back to the lobby")

	# --- the round timer: nobody votes twice in a row -> lobby
	await _boot(true)
	lobbies.clear()
	_w.lobby_requested.connect(func() -> void: lobbies.append(1))
	for a in _w.director.agents:
		if a.suspect:
			_w.director.resolve_player_shot(0, a.pos + Vector2(-60, 0), a.pos + Vector2(60, 0), 99, false)
	await _frames(4)
	_w.vote.time_left = 0.05
	await _frames(4)
	_check(_w.vote.round_no == 2 and lobbies.is_empty(), "timeout in round 1 -> round 2")
	_w.vote.time_left = 0.05
	await _frames(4)
	_check(lobbies.size() == 1, "timeout again -> lobby")

	# --- solo: one vote decides at once, no timer
	Session.start_solo()
	await _boot(false)
	_w._do_act(0, Act.READY, 0)
	restarts.clear()
	_w.restart_requested.connect(func() -> void: restarts.append(1))
	for a in _w.director.agents:
		if a.suspect:
			_w.director.resolve_player_shot(0, a.pos + Vector2(-60, 0), a.pos + Vector2(60, 0), 99, false)
	await _frames(4)
	_check(not _w.vote.timed and _w.vote.outcome == VoteState.Outcome.PENDING, "solo vote waits without a timer")
	await _seconds(1.0)
	_w._do_act(0, Act.VOTE_RETRY, 0)
	_check(restarts.size() == 1, "solo: one vote restarts the mission")
	Session.leave()


## Placeholder angled 3D view: cursor-to-ground mapping, aim hook, fog mesh, sight test, cutaway.
func _view3d_tests() -> void:
	Session.host(true)
	await _boot(true)
	var at := Vector2(800, 480)
	_place(0, at)
	# the aim hook replaces the 2D mouse position
	_w.mouse_world = func() -> Vector2: return at + Vector2(0, 100)
	_check(absf(float(_w._local_input()["aim"]) - PI * 0.5) < 0.01, "aim hook: cursor below the player aims south")
	_w.mouse_world = Callable()
	var v3 := WorldView3D.new()
	v3.world = _w
	v3.view = _w.get_node("View")
	_w.add_child(v3)
	await _frames(2)
	_check(_w.mouse_world.is_valid(), "3D view installs the aim hook")
	v3._cam_off = Vector2.ZERO  # no mouse look-ahead: the camera sits exactly on the player
	v3._cam_blend = 0.0
	v3._update_camera(0.0)
	var cfg := JsonData.load_dict("res://data/view3d.json")
	var k := 1.0 / float(cfg["px_per_m"])
	var shift := float(cfg["aim_height_m"]) / tan(deg_to_rad(float(cfg["camera"]["pitch_deg"]))) / k
	var mid := v3.get_viewport().get_visible_rect().size * 0.5
	var c := v3.ground_at(mid)
	_check(c.distance_to(at + Vector2(0, shift)) < 1.0, "3D cursor: screen center -> aim-plane point under the camera target")
	var east := v3.ground_at(mid + Vector2(100, 0))
	var north := v3.ground_at(mid + Vector2(0, -100))
	_check(east.x > c.x and absf(east.y - c.y) < 2.0, "3D cursor: right on screen is east on the ground")
	_check(north.y < c.y and absf(north.x - c.x) < 2.0, "3D cursor: up on screen is north on the ground")
	# fog mesh: one quad per sight-polygon edge
	v3.view._vis = PackedVector2Array([Vector2(700, 400), Vector2(900, 400), Vector2(900, 560)])
	v3.view._vis_origin = at
	v3._update_fog()
	var verts: PackedVector3Array = v3._fog.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(v3._fog.get_surface_count() == 1 and verts.size() == 12, "fog mesh has 4 vertices per polygon edge")
	_check(v3._in_sight(Rect2(850, 420, 10, 10)), "rect inside the sight polygon is in sight")
	_check(not v3._in_sight(Rect2(100, 100, 10, 10)), "rect outside the sight polygon is fogged")
	v3._update_level(1.0)
	_check(not v3._walls[0].visible, "far wall hidden by fog")
	_check(v3._wall_cut[10] < 1.0 and v3._wall_cut[0] == 1.0, "wall south of the player is lowered, others stay full height")
	# render smoothing: eased position moves partway, yaw turns the short way round
	var st := {}
	_check(v3._ease_pos(st, Vector2(100, 100), 0.016) == Vector2(100, 100), "eased position starts at the sim position")
	var eased := v3._ease_pos(st, Vector2(150, 100), 0.016)
	_check(eased.x > 100.0 and eased.x < 150.0, "eased position moves partway toward a stepped target")
	_check(v3._ease_pos(st, Vector2(900, 900), 0.016) == Vector2(900, 900), "eased position snaps after a teleport")
	var spin := Node3D.new()
	spin.rotation.y = 3.0
	v3._ease_yaw(spin, -3.0, 0.05)
	_check(absf(spin.rotation.y) > 3.0, "eased yaw takes the short way across +-PI")
	spin.free()
	# dark-room cue: outline-only mode = alive, flashlight off, standing in a dark room
	var ps0 := _w.players[0]
	var view: WorldView = v3.view
	ps0.flash = false
	_check(view._outline_only(ps0, Vector2(700, 330)), "dark room B without flashlight is outline-only")
	_check(not view._outline_only(ps0, Vector2(400, 300)), "lit room A is not outline-only")
	ps0.flash = true
	_check(not view._outline_only(ps0, Vector2(700, 330)), "flashlight on lifts the outline-only cue")
	ps0.flash = false
	# lighting: ceiling lights only in lit rooms, flashlight beam follows the flash flag, full-height shadow casters
	var dark_lights := 0
	for l in v3._lights:
		if _w.level.is_dark(l["pos"]):
			dark_lights += 1
	_check(v3._lights.size() >= 6 and dark_lights == 0, "ceiling lights exist and none hang in dark rooms")
	v3._update_players(0.016)
	_check(not (v3._players[0]["spot"] as Node3D).visible, "flashlight beam is off while the flash flag is off")
	ps0.flash = true
	v3._update_players(0.016)
	_check((v3._players[0]["spot"] as Node3D).visible, "flashlight beam follows the flash flag")
	ps0.flash = false
	var casters := 0
	for ch in v3.get_children():
		if ch is MeshInstance3D and (ch as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			casters += 1
	_check(casters >= _w.level.wall_rects.size() + _w.level.door_rects.size(), "every wall and door has a shadow caster")
	_w.remove_child(v3)
	v3.free()
	_check(not _w.mouse_world.is_valid(), "removing the 3D view releases the aim hook")
