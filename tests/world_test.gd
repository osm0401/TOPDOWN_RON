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
