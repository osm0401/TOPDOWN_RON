extends Node
## Offline integration test of the host-side NetWorld logic (doors, tools, commands,
## restraint, taser, camera). Runs in the real main loop so the Session autoload exists:
##   Godot_console.exe --headless --path D:\TOPDOWNRON res://tests/world_test.tscn
## Exit code 0 = all passed.

const CharacterModels := preload("res://src/game/character_models.gd")
const CharacterAnim := preload("res://src/game/character_anim.gd")
const GearModels := preload("res://src/game/gear_models.gd")

var _failed := 0
var _w: NetWorld


func _ready() -> void:
	Engine.time_scale = 2.0
	Session.host(true)
	await _boot(true)
	await _run()
	await _mission_tests()
	await _solo_tests()
	await _solo_selection_test()
	await _stage5_tests()
	await _view3d_tests()
	await _character_model_tests()
	await _audio_tests()
	await _audio_extra_tests()
	await _death_tests()
	print("---- %s" % ("FAILED: %d" % _failed if _failed > 0 else "ALL PASSED"))
	Engine.time_scale = 1.0
	remove_child(_w)  # like the game: the world goes before the connection, so no frame sends to a closed peer
	_w.free()
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
	_check(me.has_tool("lockpick") and me.has_tool("taser") and me.weapon_kinds[0] == "rifle_lethal", "solo defaults to the lethal rifle with lockpick and taser")
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
## Character models: any .glb is scaled to the figure, stood on the floor and turned to the aim,
## and the 3D view swaps / lays / tints it with the NPC state.
func _character_model_tests() -> void:
	var dir := "user://character_test/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# a box "person" 4 x 20 x 6 units, far from the origin: wrong size, place and scale on purpose
	var src := Node3D.new()
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 2.0, 0.6)
	var metal := StandardMaterial3D.new()
	metal.metallic = 1.0  # what image-to-3D generators leave behind
	box.material = metal
	body.mesh = box
	body.position = Vector3(3.0, 5.0, -2.0)
	body.scale = Vector3(10.0, 10.0, 10.0)
	src.add_child(body)
	var written := OK
	for name in ["enemy", "enemy_up", "civilian", "civilian_up", "officer"]:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		doc.append_from_scene(src, state)
		written = maxi(written, doc.write_to_filesystem(state, ProjectSettings.globalize_path(dir + name + ".glb")))
	src.free()
	_check(written == OK, "test models written")
	var cfg := {"height_m": 1.75, "yaw_deg": 90.0}
	var m := CharacterModels.make("enemy", cfg, dir)
	_check(not m.is_empty(), "a .glb in the folder becomes a character model")
	if not m.is_empty():
		var b := CharacterModels.bounds(m["node"])
		_check(absf(b.size.y - 1.75) < 0.01 and absf(b.position.y) < 0.01, "model scaled to 1.75 m and standing on the floor (%s)" % b)
		_check(absf(b.get_center().x) < 0.01 and absf(b.get_center().z) < 0.01, "model centred on the figure's position")
		_check(absf(b.size.x - 0.525) < 0.01 and absf(b.size.z - 0.35) < 0.01, "yaw 90: the model's front (+Z) now faces the aim (+X)")
		_check(absf(float(m["lie_y"]) - 0.2625) < 0.01, "lying on its back it rests on the floor (lift = half its depth)")
		var again := CharacterModels.make("enemy", cfg, dir)
		_check(again["node"] != m["node"] and again["overlay"] != m["overlay"], "every figure gets its own copy and tint")
		var meshes := CharacterModels.meshes(m["node"])
		_check(not meshes.is_empty() and meshes.all(func(mi: MeshInstance3D) -> bool: return mi.material_overlay == m["overlay"]), "the tint covers every surface")
		var mat := meshes[0].mesh.surface_get_material(0) as BaseMaterial3D
		_check(mat != null and is_zero_approx(mat.metallic), "a metallic 1.0 left by the generator (no metallic texture) is made non-metallic")
		(m["node"] as Node).free()
		(again["node"] as Node).free()
	_check(CharacterModels.make("nobody", cfg, dir).is_empty(), "no file: no model (the primitive figure stays)")
	var up := CharacterModels.make("enemy_up", {"height_m": 1.75, "up_height_m": 2.05, "yaw_deg": 90.0}, dir)
	_check(absf(CharacterModels.bounds(up["node"]).size.y - 2.05) < 0.01, "a hands-up model is fitted fingertips included (2.05 m)")
	(up["node"] as Node).free()
	_walk_rig_tests(dir)

	# in the 3D view: models replace the shapes and follow the NPC state
	CharacterModels.folder = dir
	CharacterModels.release()
	Session.host(true)
	await _boot(true)
	var v3 := WorldView3D.new()
	v3.world = _w
	v3.view = _w.get_node("View")
	_w.add_child(v3)
	await _frames(2)
	_check(not (v3._players[0]["model"] as Dictionary).is_empty(), "3D view: the officer uses the model")
	v3._update_players(0.016)
	var rim: ShaderMaterial = v3._players[0]["rim"]
	var tint: Color = rim.get_shader_parameter("tint")
	_check(CharacterModels.meshes(v3._players[0]["model"]["node"])[0].material_overlay == rim and is_equal_approx(tint.b, WorldView.PLAYER_COLORS[0].b)
			and is_equal_approx(float(rim.get_shader_parameter("rim")), float(v3._cfg["characters"]["player_rim"])), "3D view: the officer keeps its player colour as a rim glow")
	var i := 0
	while _agent(i).dormant or _agent(i).brain.role != NpcBrain.Role.ENEMY:
		i += 1
	var n: Dictionary = v3._npcs[i]
	_agent(i).brain.state = NpcBrain.State.SURRENDER
	v3._update_npcs(0.016)
	_check((n["model_up"]["node"] as Node3D).visible and not (n["model"]["node"] as Node3D).visible and not (n["arms"] as Node3D).visible,
			"3D view: surrender swaps in the hands-up model (no extra arms)")
	_agent(i).brain.state = NpcBrain.State.DOWN
	v3._update_npcs(0.016)
	var rig: Node3D = n["rig"]
	_check(rig.position.y < float(n["model"]["lie_front"]) * 0.5, "3D view: going down it topples over, not straight to the floor")
	for f in 40:
		v3._update_npcs(0.016)
	_check((n["model"]["node"] as Node3D).visible and not (n["model_up"]["node"] as Node3D).visible
			and absf(rig.position.y - float(n["model"]["lie_front"])) < 0.001 and (rig.basis * Vector3.RIGHT).y < -0.99,
			"3D view: a downed NPC model lies face down (its front, rig +X, toward the floor), resting on the floor")
	_agent(i).brain.state = NpcBrain.State.DEAD
	v3._update_npcs(0.016)
	_check(is_equal_approx((n["model"]["overlay"] as StandardMaterial3D).albedo_color.a, 0.6), "3D view: a dead NPC model is greyed")
	# walking: the stride follows the drawn motion and settles back to standing
	var sk := n["model"]["skeleton"] as Skeleton3D
	var rest := Quaternion.IDENTITY  # a standing thigh
	_agent(i).brain.state = NpcBrain.State.IDLE
	_agent(i).brain.facing = 0.0
	var from := _agent(i).pos
	for f in 30:  # 1.8 m/s east, the way it faces
		_agent(i).pos = from + Vector2(90.0 * 0.016 * f, 0.0)
		_agent(i).home = _agent(i).pos
		v3._update_npcs(0.016)
	_check(float(n["walk_amount"]) > 0.9 and absf((n["walk_v"] as Vector3).length() - 1.8) < 0.1, "3D view: a moving NPC walks at its drawn speed (%.2f m/s)" % (n["walk_v"] as Vector3).length())
	var walk_dir: Vector3 = sk.global_basis.inverse() * n["walk_v"]
	_check(walk_dir.normalized().z > 0.95, "3D view: walking where it faces is forward for the model (%s)" % walk_dir.normalized())
	var stepping := false
	for f in 20:
		_agent(i).pos += Vector2(90.0 * 0.016, 0.0)
		_agent(i).home = _agent(i).pos
		v3._update_npcs(0.016)
		stepping = stepping or not sk.get_bone_pose_rotation(CharacterModels.Bone.THIGH_L).is_equal_approx(rest)
	_check(stepping, "3D view: the legs swing while it walks")
	for f in 90:
		v3._update_npcs(0.016)
	_check(float(n["walk_amount"]) < 0.01 and sk.get_bone_pose_rotation(CharacterModels.Bone.THIGH_L).is_equal_approx(rest), "3D view: standing still it settles back to the rest pose")
	_agent(i).brain.state = NpcBrain.State.DOWN
	for f in 3:
		_agent(i).pos += Vector2(90.0 * 0.016, 0.0)
		v3._update_npcs(0.016)
	_check(is_zero_approx(float(n["walk_amount"])), "3D view: a downed NPC does not walk even when moved")
	# gear: the officer's rifle in the hands and pistol holstered; swapped, pistol out and rifle slung
	var cop: Dictionary = v3._players[0]["model"]
	var ps := _w.players[0]
	ps.active = 0
	v3._update_players(0.016)
	var gear: Dictionary = cop["gear"]
	_check(gear.has("hand") and (gear["hand"] as Node3D).name.begins_with("rifle") and (gear["hand"] as Node3D).visible
			and (gear["holster"] as Node3D).name == "pistol" and not (v3._players[0]["gun"] as Node3D).visible,
			"3D view: the officer holds the rifle, pistol holstered (no box gun)")
	ps.active = 1
	v3._update_players(0.016)
	gear = cop["gear"]
	_check((gear["hand"] as Node3D).name == "pistol" and (gear["back"] as Node3D).name.begins_with("rifle") and (gear["back"] as Node3D).visible,
			"3D view: with the pistol out the rifle is slung")
	ps.active = 0
	_check(v3._gun_point(cop, "muzzle") != Vector3.INF, "3D view: the officer's muzzle is known (tracers and the laser start there)")
	_agent(i).brain.state = NpcBrain.State.RESTRAINED
	v3._update_npcs(0.016)
	var npc_sk := n["model"]["skeleton"] as Skeleton3D
	var rest_hips := npc_sk.get_bone_rest(CharacterModels.Bone.HIPS).origin.y
	var first := npc_sk.get_bone_pose_position(CharacterModels.Bone.HIPS).y
	_check(first > rest_hips - 0.1, "3D view: a new pose blends in (one frame in, the hips have barely moved)")
	for f in 30:
		v3._update_npcs(0.016)
	_check((n["model"]["gear"] as Dictionary).has("cuffs") and npc_sk.get_bone_pose_position(CharacterModels.Bone.HIPS).y < npc_sk.get_bone_rest(CharacterModels.Bone.HIPS).origin.y - 0.3
			and is_equal_approx((n["rig"] as Node3D).scale.y, 1.0), "3D view: a restrained NPC kneels in cuffs (not squashed)")
	_check((n["dropped"] as Node3D).name == "pistol", "3D view: a dropped weapon is a pistol on the floor")
	v3.zoom_by(0.001)
	_check(is_equal_approx(v3._zoom_to, float(v3._cfg["camera"]["zoom_min"])), "zoom in stops at zoom_min")
	v3.zoom_by(1000.0)
	_check(is_equal_approx(v3._zoom_to, float(v3._cfg["camera"]["zoom_max"])), "zoom out stops at zoom_max")
	WorldView3D._zoom_to = 1.0
	v3.free()
	CharacterModels.folder = CharacterModels.DIR
	CharacterModels.release()
	for name in ["enemy", "enemy_up", "civilian", "civilian_up", "officer"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + name + ".glb"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## The auto-rig on a box "person" (legs, torso, arms a little off the body, head) written as a
## .glb: joints at human proportions, every part skinned to its bone; then CharacterAnim's poses on
## it: walking forward and sideways, standing, rifle and pistol grips, kneeling, crouching, cuffed.
func _walk_rig_tests(dir: String) -> void:
	var src := Node3D.new()
	var parts := {  # name: [size, centre]
		"leg_l": [Vector3(0.14, 0.82, 0.16), Vector3(0.1, 0.41, 0.0)], "leg_r": [Vector3(0.14, 0.82, 0.16), Vector3(-0.1, 0.41, 0.0)],
		"torso": [Vector3(0.4, 0.62, 0.24), Vector3(0.0, 1.09, 0.0)], "head": [Vector3(0.2, 0.3, 0.22), Vector3(0.0, 1.6, 0.0)],
		"arm_l": [Vector3(0.08, 0.7, 0.1), Vector3(0.27, 1.05, 0.0)], "arm_r": [Vector3(0.08, 0.7, 0.1), Vector3(-0.27, 1.05, 0.0)]}
	for part: String in parts:
		var mi := MeshInstance3D.new()
		mi.name = part
		var box := BoxMesh.new()
		box.size = parts[part][0]
		box.subdivide_height = 24
		box.subdivide_width = 3
		box.subdivide_depth = 3
		mi.mesh = box
		mi.position = parts[part][1]
		src.add_child(mi)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(src, state)
	var written := doc.write_to_filesystem(state, ProjectSettings.globalize_path(dir + "walker.glb"))
	src.free()
	_check(written == OK, "box person written")
	var m := CharacterModels.make("walker", {"height_m": 1.75, "yaw_deg": 0.0}, dir)
	add_child(m["node"])  # bone poses resolve inside the tree
	var sk := m.get("skeleton") as Skeleton3D
	_check(sk != null and sk.get_bone_count() == CharacterModels.BONE_NAMES.size(), "a model without bones is rigged when it loads")
	if sk == null:
		return
	var B := CharacterModels.Bone
	var h := 1.75
	var at := func(b: int) -> Vector3: return sk.get_bone_global_rest(b).origin
	_check(at.call(B.HIPS).y > 0.85 and at.call(B.HIPS).y < 0.93 and absf(at.call(B.SHIN_L).y - 0.27 * h) < 0.01 and absf(at.call(B.FOOT_L).y - 0.05 * h) < 0.01,
			"hips, knees and ankles at human proportions (%s, %s, %s)" % [at.call(B.HIPS), at.call(B.SHIN_L), at.call(B.FOOT_L)])
	_check(absf(at.call(B.THIGH_L).x - 0.1) < 0.02 and absf(at.call(B.THIGH_R).x + 0.1) < 0.02, "each thigh bone sits in its leg (left = +X, the model faces +Z) (%s, %s)" % [at.call(B.THIGH_L), at.call(B.THIGH_R)])
	_check(absf(at.call(B.CHEST).y - 0.71 * h) < 0.01 and absf(at.call(B.HEAD).y - 0.86 * h) < 0.01, "chest and neck joints")
	_check(at.call(B.UPPER_ARM_L).x > 0.2 and at.call(B.UPPER_ARM_R).x < -0.2 and absf(at.call(B.UPPER_ARM_L).y - 0.815 * h) < 0.01
			and at.call(B.FOREARM_L).x > 0.2 and absf(at.call(B.FOREARM_L).y - 0.62 * h) < 0.01, "shoulders and elbows in the arms")
	var hand_l: Vector3 = sk.get_meta("hand_l")
	_check(hand_l.x > 0.22 and hand_l.y > 0.69 and hand_l.y < 0.85, "the left hand's centre is found at the bottom of the left arm (%s)" % hand_l)
	# which bone carries each part
	var expect := {"foot": [B.FOOT_L, B.FOOT_R], "shin": [B.SHIN_L, B.SHIN_R], "hand": [B.FOREARM_L, B.FOREARM_R], "upper": [B.UPPER_ARM_L, B.UPPER_ARM_R], "head": [B.HEAD, B.HEAD]}
	var weights_ok := true
	var parts_ok := true
	var bad := ""
	for mi: MeshInstance3D in CharacterModels.meshes(m["node"]):
		var arr := (mi.mesh as ArrayMesh).surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		_check(arr[Mesh.ARRAY_NORMAL] != null, "the rigged mesh has normals")
		for k in v.size():
			var sum := w[k * 4] + w[k * 4 + 1] + w[k * 4 + 2] + w[k * 4 + 3]
			weights_ok = weights_ok and absf(sum - 1.0) < 0.001
			var p := v[k]
			var part := ""
			if p.y < 0.04:
				part = "foot"
			elif p.y > 0.2 and p.y < 0.35:
				part = "shin"
			elif p.y > 0.72 and p.y < 0.8 and absf(p.x) > 0.24:
				part = "hand"
			elif p.y > 1.22 and p.y < 1.3 and absf(p.x) > 0.24:
				part = "upper"
			elif p.y > 1.6:
				part = "head"
			if part != "" and (bones[k * 4] != expect[part][0 if p.x > 0.0 else 1] or w[k * 4] < 0.99):
				parts_ok = false
				bad = "%s at %s: bone %d weight %.2f" % [part, p, bones[k * 4], w[k * 4]]
	_check(weights_ok, "every vertex's weights add up to 1")
	_check(parts_ok, "feet, shins, hands, upper arms and head each follow their own bone %s" % bad)

	var cfg: Dictionary = JsonData.load_dict("res://data/view3d.json")["characters"]
	var S := CharacterAnim.Stance
	var H := CharacterAnim.Hold
	var pos := func(b: int) -> Vector3:
		sk.force_update_all_bone_transforms()
		return sk.get_bone_global_pose(b).origin
	var hand := func(side: int) -> Vector3:  # the posed hand centre, from the skeleton itself
		sk.force_update_all_bone_transforms()
		var bone: int = B.FOREARM_L if side == 0 else B.FOREARM_R
		var pose := sk.get_bone_global_pose(bone)
		var rest_hand: Vector3 = sk.get_meta("hand_l" if side == 0 else "hand_r")
		return pose.origin + pose.basis * (rest_hand - at.call(bone))
	var knee_l: Vector3 = at.call(B.SHIN_L)
	CharacterAnim.pose(m, {"phase": PI * 0.5, "amount": 1.0, "speed": 1.8, "dir": Vector3.BACK}, cfg)
	_check(pos.call(B.SHIN_L).z > knee_l.z + 0.1 and pos.call(B.SHIN_R).z < knee_l.z - 0.1, "mid-stride forward: the left knee ahead, the right behind")
	_check(sk.get_bone_pose_position(B.HIPS).y < sk.get_bone_rest(B.HIPS).origin.y - 0.01, "legs apart: the hips dip")
	_check(hand.call(0).z < hand.call(1).z - 0.15, "the left hand swings back as the left leg goes forward")
	CharacterAnim.pose(m, {"phase": PI * 0.5, "amount": 1.0, "speed": 1.8, "dir": Vector3.RIGHT}, cfg)
	_check(pos.call(B.SHIN_L).x > knee_l.x + 0.1 and absf(pos.call(B.SHIN_L).z - knee_l.z) < 0.02, "sideways: the legs step sideways, not forward")
	CharacterAnim.pose(m, {}, cfg)
	_check(pos.call(B.SHIN_L).is_equal_approx(knee_l) and hand.call(0).y < 0.85 and absf(hand.call(0).z) < 0.06, "standing: legs at rest, arms hanging")
	# rifle: right hand on the grip, left on the handguard, muzzle out in front
	var rifle := GearModels.make("rifle_lethal")
	sk.add_child(rifle)
	m["gear"] = {"hand": rifle}
	CharacterAnim.pose(m, {"hold": H.RIFLE}, cfg)
	var muzzle: Transform3D = m.get("muzzle", Transform3D())
	_check(hand.call(1).distance_to(rifle.transform.origin) < 0.03 and hand.call(0).distance_to(rifle.transform * (rifle.get_meta("fore") as Vector3)) < 0.06,
			"rifle: right hand on the grip, left hand on the handguard (%.3f, %.3f)" % [hand.call(1).distance_to(rifle.transform.origin), hand.call(0).distance_to(rifle.transform * (rifle.get_meta("fore") as Vector3))])
	_check(muzzle.basis.z.z > 0.97 and muzzle.origin.z > 0.6 and muzzle.origin.y > 1.2, "rifle: the muzzle points ahead at shoulder height (%s)" % muzzle.origin)
	var pistol := GearModels.make("pistol")
	sk.add_child(pistol)
	m["gear"] = {"hand": pistol}
	CharacterAnim.pose(m, {"hold": H.PISTOL}, cfg)
	_check(hand.call(1).distance_to(pistol.transform.origin) < 0.03 and hand.call(0).distance_to(pistol.transform * (pistol.get_meta("fore") as Vector3)) < 0.05,
			"pistol: both hands on the grip")
	CharacterAnim.pose(m, {"hold": H.PISTOL_ONE, "aim": Vector3(1, 0, 1).normalized()}, cfg)
	_check((m["muzzle"] as Transform3D).basis.z.dot(Vector3(1, 0, 1).normalized()) > 0.97, "one-handed: the pistol points where it aims")
	m["gear"] = {}
	CharacterAnim.pose(m, {"stance": S.KNEEL, "hold": H.CUFFED}, cfg)
	var hips_y := pos.call(B.HIPS).y as float
	_check(hips_y < at.call(B.HIPS).y - 0.3 and pos.call(B.SHIN_L).y < 0.12, "kneeling: hips down, knees on the floor (%.2f, %.2f)" % [hips_y, pos.call(B.SHIN_L).y])
	_check(hand.call(0).z < pos.call(B.SPINE).z - 0.05 and hand.call(0).distance_to(hand.call(1)) < 0.15, "cuffed: wrists together behind the back")
	CharacterAnim.pose(m, {"stance": S.CROUCH, "hold": H.COVER}, cfg)
	_check(pos.call(B.HIPS).y < at.call(B.HIPS).y * 0.6 and pos.call(B.FOOT_L).distance_to(at.call(B.FOOT_L)) < 0.1 and hand.call(0).y > pos.call(B.HEAD).y,
			"crouching: hips low, feet planted, hands over the head")
	(m["node"] as Node).free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "walker.glb"))


func _view3d_tests() -> void:
	_check(WorldView._start_3d() == bool(JsonData.load_dict("res://data/view3d.json")["start_3d"]), "the start view follows data/view3d.json start_3d (no --view2d / --view3d)")
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


## Sound hearing for the local officer: same SoundProp rules as NPC hearing, muffled behind solids.
func _audio_tests() -> void:
	Session.host(true)
	await _boot(true)
	var au := GameAudio.new()
	au.world = _w
	_w.add_child(au)
	await _frames(2)
	_check(AudioServer.get_bus_index(GameAudio.BUS_SFX) >= 0 and AudioServer.get_bus_index(GameAudio.BUS_MUFFLED) >= 0, "sound buses exist")
	var near := au.hearing(Vector2(300, 500), Vector2(260, 500), 120.0)
	_check(float(near["loud"]) > 0.6 and not near["muffled"], "a footstep 40 px away is loud and clear")
	_check(float(au.hearing(Vector2(900, 500), Vector2(260, 500), 120.0)["loud"]) == 0.0, "a footstep beyond its radius is silent")
	var clear := au.hearing(Vector2(500, 500), Vector2(300, 500), 600.0)  # 200 px along the open corridor
	var walled := au.hearing(Vector2(300, 300), Vector2(300, 500), 600.0)  # 200 px but through a wall into room A
	_check(not clear["muffled"] and walled["muffled"], "a wall in the way muffles the sound")
	_check(float(walled["loud"]) < float(clear["loud"]), "the wall also makes it quieter")
	_check(_w.level.get_door_state(1) == Level.DoorState.CLOSED, "test door starts closed")
	var door := au.hearing(Vector2(820, 300), Vector2(820, 500), 600.0)  # through the closed door of room B
	_check(door["muffled"] and float(door["loud"]) < float(clear["loud"]), "a closed door muffles and quiets the sound")
	# graded dulling, room reverb, ear ringing
	_check(au.bus_for(0.9, false) == GameAudio.BUS_SFX and au.bus_for(0.5, false) == GameAudio.BUS_MID and au.bus_for(0.1, false) == GameAudio.BUS_FAR, "farther sounds go through duller buses")
	_check(au.bus_for(0.9, true) == GameAudio.BUS_MUFFLED, "sounds behind solids always use the muffled bus")
	var hall := au.reverb_for(Vector2(700, 500))  # long corridor
	var room := au.reverb_for(Vector2(400, 300))  # room A
	var outside := au.reverb_for(Vector2(60, 500))
	_check(float(hall["wet"]) > float(outside["wet"]) and float(room["room_size"]) > float(outside["room_size"]), "indoor spaces ring more than outside")
	_check(float(hall["room_size"]) > float(room["room_size"]), "a long corridor rings longer than a small room")
	_check(au._ear == 0.0, "ears start clear")
	au._on_sound(SoundProp.Kind.GUNSHOT, _w.players[0].pos + Vector2(0, 40))  # a teammate's shot right beside you
	_check(au._ear > 0.6, "a loud nearby shot from someone else deafens")
	au._ear = 0.0
	au._on_sound(SoundProp.Kind.GUNSHOT, _w.players[0].pos + Vector2(0, 40))
	_check(au._ear == 0.0, "ringing does not retrigger inside the minimum gap")
	au._ear_gap = 0.0
	au._on_sound(SoundProp.Kind.GUNSHOT, _w.players[0].pos)  # your own shot
	_check(au._ear == 0.0, "your own shots do not deafen you")
	# generated/recorded samples (not in git): when present they must be usable mono streams
	var path := "res://assets/audio/rifle_1.wav"
	if ResourceLoader.exists(path):
		var s := load(path) as AudioStreamWAV
		_check(s != null and not s.stereo and s.get_length() > 0.5 and s.get_length() < 4.0, "rifle sample is a mono stream of a sensible length")
	else:
		print("SKIP rifle sample test: ", path, " not present (synthesized stand-in is used)")
	_w.remove_child(au)
	au.free()


## A killed NPC never gets back up; a non-lethal hit only stuns (wakes up unarmed, surrendering).
func _death_tests() -> void:
	var S := NpcBrain.State
	Session.host(true)
	await _boot(true)
	var a := _agent(0)
	var at := a.pos
	_w.director.resolve_player_shot(0, at + Vector2(-60, 0), at + Vector2(60, 0), 99, false)
	_check(a.brain.state == S.DEAD, "lethal hit kills the enemy")
	for i in 20:  # twenty seconds of gunfire and shouting around the body
		_w._emit_sound(SoundProp.Kind.GUNSHOT, at + Vector2(30, 0))
		_w.director.command(0, NpcBrain.Cmd.FREEZE)
		await _seconds(1.0)
	_check(a.brain.state == S.DEAD and not a.brain.alive() and a.brain.hp == 0, "a dead enemy stays dead")
	var packed := _w.director.pack()
	_w.director.unpack(packed[0], packed[1], packed[2])
	_check(a.brain.state == S.DEAD, "dead survives a snapshot round trip")

	await _boot(true)
	var b := _agent(0)
	var bat := b.pos
	_w.director.resolve_player_shot(0, bat + Vector2(-60, 0), bat + Vector2(60, 0), 0, true)
	_check(b.brain.state == S.DOWN and b.brain.alive() and b.brain.hp > 0, "non-lethal hit only knocks the enemy down (still alive)")
	await _seconds(float(_w.tuning["npc"]["stun_s"]) + 1.5)
	_check(b.brain.alive() and not b.brain.armed and b.brain.state != S.DOWN, "after the stun the enemy is back up, unarmed")


## The lobby selection decides the solo weapon (the default is the lethal rifle).
func _solo_selection_test() -> void:
	Session.start_solo()
	Session.solo_loadout["primary"] = "rifle_nonlethal"
	await _boot(false)
	_check(_w.players[0].weapon_kinds[0] == "rifle_nonlethal", "solo uses the non-lethal rifle when the lobby selects it")
	Session.solo_loadout["primary"] = "rifle_lethal"
	Session.leave()


## Sound variants, voice file names, recorded-line mapping and the F7 audition panel.
func _audio_extra_tests() -> void:
	Session.host(true)
	await _boot(true)
	var au := GameAudio.new()
	au.world = _w
	_w.add_child(au)
	await _frames(2)
	# no variant is played twice in a row
	var set_a: Array = [SfxSynth.footstep(1), SfxSynth.footstep(2), SfxSynth.footstep(3)]
	var repeats := 0
	var last: Variant = null
	for i in 200:
		var pick: Variant = au._pick("k", set_a)
		if pick == last:
			repeats += 1
		last = pick
	_check(repeats == 0, "the same variant never plays twice in a row")
	# faint sounds use the _far set when one exists
	au._bank = {"rifle": [1], "rifle_far": [2], "pistol": [3]}
	_check(au.set_key("rifle", 0.1) == "rifle_far" and au.set_key("rifle", 0.9) == "rifle" and au.set_key("pistol", 0.1) == "pistol", "faint sounds switch to the far set only when it exists")
	_check(GameAudio.sample_streams("no_such_sound").is_empty(), "no files means no replacement (the synthesized stand-in stays)")
	var bank := GameAudio.synthesize(["heart", "ring"])
	_check(bank.keys() == ["heart", "ring"] and (bank["heart"][0] as AudioStreamWAV).data == SfxSynth.heart().data,
			"the stand-in bank synthesizes exactly the sounds asked for (sounds with files are skipped)")
	var missing := GameAudio.SAMPLE_KEYS.filter(func(k: String) -> bool: return not k.ends_with("_far") and not GameAudio.SYNTH_KEYS.has(k))
	_check(missing.is_empty(), "every sound a file can replace has a stand-in (missing: %s)" % [missing])
	_check(not GameAudio.has_samples("no_such_sound"), "no file: the stand-in is the one that plays")
	_check(GameAudio.wait_prepared().is_empty(), "headless: no background synthesis was started")
	# recorded voice lines: file names follow commands.json order
	var lines := JsonData.load_dict("res://data/commands.json")
	var stems := GameAudio.voice_stems(lines)
	_check(stems[str(lines["weapon_drop"][0])] == "voice_weapon_drop_0" and stems[str(lines["turn"][3])] == "voice_turn_3", "command sentences map to voice_<command>_<line>")
	_check(stems[GameAudio.SCREAM_LINE] == "voice_npc_scream" and stems.size() == 17, "all 16 command lines and the NPC scream have a file name")
	_check(GameAudio.voice_lines(lines, "res://no_such_dir/").is_empty(), "no recordings means no voice lines")
	# room tone files loop over their whole length
	var tone := SfxSynth.footstep(1)
	GameAudio.loop_whole(tone)
	_check(tone.loop_mode == AudioStreamWAV.LOOP_FORWARD and tone.loop_end == tone.data.size() / 2, "loop_whole makes a sample repeat over its whole length")
	# distance buses carry the echo and low thump; the far file sets can be switched off
	var far_bus := AudioServer.get_bus_index(GameAudio.BUS_FAR)
	var kinds: Array[String] = []
	for e in AudioServer.get_bus_effect_count(far_bus):
		kinds.append(AudioServer.get_bus_effect(far_bus, e).get_class())
	_check(kinds == ["AudioEffectLowPassFilter", "AudioEffectLowShelfFilter", "AudioEffectReverb"], "the far bus dulls, keeps the thump and adds an echo tail")
	au._bank = {"rifle": [1], "rifle_far": [2]}
	au.use_far_sets = false
	_check(au.set_key("rifle", 0.1) == "rifle", "with far sets off, faint sounds keep the normal set")
	au.use_far_sets = true
	# reverb presets grow with the room
	_check(float(au.reverb_for_size(23.0)["room_size"]) > float(au.reverb_for_size(5.0)["room_size"]) and float(au.reverb_outdoor()["wet"]) < float(au.reverb_for_size(5.0)["wet"]), "reverb presets grow with the room and outdoors stays dry")
	# the audition panel (needs real streams in the bank)
	au._bank = {"rifle": [SfxSynth.footstep(1)]}
	var panel := AudioAudition.new()
	panel.audio = au
	au.add_child(panel)
	await _frames(1)
	var f7 := InputEventKey.new()
	f7.physical_keycode = KEY_F7
	f7.pressed = true
	panel._unhandled_input(f7)
	_check(panel.visible, "F7 opens the audition panel")
	var next_room := InputEventKey.new()
	next_room.physical_keycode = KEY_EQUAL
	next_room.pressed = true
	panel._unhandled_input(next_room)
	panel._unhandled_input(next_room)
	_check(not au.audition_reverb.is_empty(), "choosing a room in the panel overrides the reverb")
	panel._unhandled_input(f7)
	_check(not panel.visible and au.audition_reverb.is_empty(), "closing the panel gives the reverb back to the room")
	_w.remove_child(au)
	au.free()
