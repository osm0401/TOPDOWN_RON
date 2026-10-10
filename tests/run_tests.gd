extends SceneTree
## Headless test runner (no addons):
## Godot_console.exe --headless --path D:\TOPDOWNRON --script tests/run_tests.gd

const PLAYER_R := 14.0
var _failed := 0


func _initialize() -> void:
	_test_room_code()
	_test_classify_ip()
	_test_weapon()
	_test_geom_sound_light()
	_test_brain()
	await _test_level()
	await _test_level_doors()
	await _test_director()
	print("---- %s" % ("FAILED: %d" % _failed if _failed > 0 else "ALL PASSED"))
	quit(1 if _failed > 0 else 0)


func _test_weapon() -> void:
	var w := WeaponState.create(3, 2, 0.25, 1.0)
	_check(w.current == 3 and str(w.spares) == "[3, 3]", "weapon starts full with spare mags")
	_check(w.try_fire() and w.current == 2, "fire uses one round")
	_check(not w.try_fire(), "fire interval blocks immediate refire")
	w.update(0.3)
	_check(w.try_fire() and w.current == 1, "fire again after interval")
	_check(w.start_reload(), "reload starts when a fuller spare exists")
	_check(not w.try_fire(), "cannot fire while reloading")
	_check(not w.update(0.5) and w.reloading, "reload not finished yet")
	_check(w.update(0.6) and not w.reloading, "reload finished")
	_check(w.current == 3 and str(w.spares) == "[1, 3]", "old magazine keeps its remaining rounds")
	var packed := w.to_packed()
	var copy := WeaponState.new()
	copy.from_packed(packed)
	_check(copy.current == 3 and str(copy.spares) == "[1, 3]" and not copy.reloading, "pack/unpack roundtrip")
	var empty := WeaponState.create(2, 1, 0.0, 0.5)
	empty.try_fire()
	empty.try_fire()
	_check(not empty.try_fire(), "empty magazine cannot fire")
	empty.start_reload()
	empty.update(0.6)
	empty.try_fire()
	empty.try_fire()
	empty.update(0.0)
	_check(not empty.start_reload(), "no reload when spares are not fuller")


func _test_level() -> void:
	var lv := Level.new()
	_check(lv.load_map("res://data/map_01.json"), "map loads")
	root.add_child(lv)
	await physics_frame
	await physics_frame
	# door B (index 1) is in the corridor-north wall at x 780..860
	var a := Vector2(820, 500)
	var b := Vector2(820, 300)
	_check(not lv.has_los(a, b), "closed door blocks line of sight")
	_check(not lv.has_los(Vector2(300, 500), Vector2(300, 300)), "wall blocks line of sight")
	_check(lv.has_los(Vector2(300, 500), Vector2(1300, 500)), "corridor is clear")
	lv.toggle_door(1, 1)
	await physics_frame
	await physics_frame
	_check(lv.has_los(a, b), "open door lets sight through")
	_check(lv.door_actor[1] == 1, "door remembers who toggled it")

	var poly_open := lv.visibility_polygon(a, 700.0)
	_check(_min_y(poly_open) < 430.0, "open door: fog polygon reaches into the room")
	lv.toggle_door(1, 2)
	await physics_frame
	await physics_frame
	var poly_closed := lv.visibility_polygon(a, 700.0)
	_check(_min_y(poly_closed) >= 430.0, "closed door: fog polygon stays in the corridor")

	var near := lv.nearest_door(Vector2(150, 480), 80.0)
	_check(near == 5, "entrance door is nearest from the spawn")
	_check(lv.nearest_door(Vector2(700, 500), 30.0) == -1, "no door in range in mid corridor")
	lv.toggle_door(4, 1)
	var packed := lv.pack_doors()
	var lv2 := Level.new()
	lv2.load_map("res://data/map_01.json")
	lv2.unpack_doors(packed)
	_check(lv2.is_door_open(4) and not lv2.is_door_open(1) and lv2.door_actor[4] == 1, "door state pack/unpack")

	var body := CharacterBody2D.new()
	body.collision_layer = 2
	body.collision_mask = Level.WALL_LAYER
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.position = Vector2(300, 500)
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = PLAYER_R
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)
	for i in 60:
		body.velocity = Vector2(0, -220)
		body.move_and_slide()
		await physics_frame
	_check(body.position.y >= 450.0 + PLAYER_R - 1.0, "player cannot walk through a wall (y=%.1f)" % body.position.y)
	body.position = Vector2(150, 500)
	for i in 30:
		body.velocity = Vector2(220, 0)
		body.move_and_slide()
		await physics_frame
	_check(body.position.x <= 200.0 - PLAYER_R + 1.0, "closed entrance door blocks the player (x=%.1f)" % body.position.x)
	lv.toggle_door(5, 1)
	await physics_frame
	await physics_frame
	for i in 30:
		body.velocity = Vector2(220, 0)
		body.move_and_slide()
		await physics_frame
	_check(body.position.x > 230.0, "open entrance door lets the player in (x=%.1f)" % body.position.x)
	root.remove_child(body)
	body.free()
	root.remove_child(lv)
	lv.free()


func _tuning() -> Dictionary:
	return JsonData.load_dict("res://data/tuning.json")


func _diff(preset: String = "normal") -> Dictionary:
	var presets: Dictionary = JsonData.load_dict("res://data/difficulty.json")["presets"]
	return presets[preset]


func _brain_params(preset: String = "normal") -> Dictionary:
	var t := _tuning()
	var p := {}
	p.merge(t["npc"])
	p.merge(_diff(preset), true)
	var c: Dictionary = t["commands"]
	p["chance"] = c["chance"].duplicate()
	for k in ["suppressed_bonus", "hurt_bonus", "outnumbered_bonus", "engaged_mult", "civilian_chance"]:
		p[k] = c[k]
	return p


func _test_geom_sound_light() -> void:
	var r := Rect2(10, 10, 20, 20)
	_check(Geom2D.segment_hits_rect(Vector2(0, 20), Vector2(40, 20), r), "segment crossing a rect hits")
	_check(not Geom2D.segment_hits_rect(Vector2(0, 0), Vector2(40, 0), r), "segment beside a rect misses")
	_check(not Geom2D.segment_hits_rect(Vector2(0, 20), Vector2(5, 20), r), "segment that stops short misses")
	_check(Geom2D.segment_hits_rect(Vector2(20, 0), Vector2(20, 40), r), "vertical segment hits")
	_check(Geom2D.cone_contains(Vector2.ZERO, 0.0, 90.0, 100.0, Vector2(50, 10)), "point inside cone")
	_check(not Geom2D.cone_contains(Vector2.ZERO, 0.0, 90.0, 100.0, Vector2(50, 80)), "point outside cone angle")
	_check(not Geom2D.cone_contains(Vector2.ZERO, 0.0, 90.0, 100.0, Vector2(150, 0)), "point beyond cone range")

	var pen: Dictionary = _tuning()["sound_penalty"]
	var none := {"walls": 0, "closed": 0, "ajar": 0}
	var wall := {"walls": 1, "closed": 0, "ajar": 0}
	var door := {"walls": 0, "closed": 1, "ajar": 0}
	var ajar := {"walls": 0, "closed": 0, "ajar": 1}
	_check(SoundProp.is_heard(300.0, none, pen, 600.0, 1.0), "open air: heard")
	_check(SoundProp.effective_distance(300.0, door, pen) > SoundProp.effective_distance(300.0, wall, pen), "closed door muffles more than a wall")
	_check(SoundProp.effective_distance(300.0, ajar, pen) < SoundProp.effective_distance(300.0, wall, pen), "ajar door muffles less than a wall")
	_check(SoundProp.is_heard(300.0, wall, pen, 600.0, 0.8) and not SoundProp.is_heard(300.0, door, pen, 600.0, 0.8), "closed door cuts a sound a wall lets through")
	_check(SoundProp.loudness(0.0, none, pen, 600.0, 1.0) == 1.0 and SoundProp.loudness(900.0, none, pen, 600.0, 1.0) == 0.0, "loudness range")

	_check(LightModel.visibility(false, 500.0, false, 70.0) == LightModel.Seen.IDENTIFIED, "lit room: identified")
	_check(LightModel.visibility(true, 500.0, true, 70.0) == LightModel.Seen.IDENTIFIED, "dark room in flashlight beam: identified")
	_check(LightModel.visibility(true, 50.0, false, 70.0) == LightModel.Seen.SILHOUETTE, "dark room, close: silhouette only")
	_check(LightModel.visibility(true, 200.0, false, 70.0) == LightModel.Seen.NONE, "dark room, far: nothing")


func _new_brain(role: int, preset: String = "normal", feign: bool = false, seed_value: int = 7) -> NpcBrain:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return NpcBrain.new(role, _brain_params(preset), rng, feign)


func _run_brain(b: NpcBrain, seconds: float, see_at: Variant = null, step: float = 0.05) -> void:
	var t := 0.0
	while t < seconds:
		if see_at != null:
			b.see_player(see_at)
		b.tick(step)
		t += step


func _test_brain() -> void:
	var E := NpcBrain.Role.ENEMY
	var S := NpcBrain.State

	var b := _new_brain(E)
	b.hear("gunshot", Vector2(100, 0), 0.5)
	b.tick(0.05)
	var out := b.tick(0.05)
	_check(b.state == S.INVESTIGATE and out["move_to"] == Vector2(100, 0), "enemy hears a gunshot: investigates the spot")
	b.arrived()
	_run_brain(b, 3.5)
	_check(b.state == S.IDLE, "nothing found: back to idle")

	b = _new_brain(E)
	b.see_player(Vector2(200, 0))
	b.tick(0.05)
	_check(b.state == S.SPOTTED, "sees the player: spotted")
	_run_brain(b, 0.5, Vector2(200, 0))
	_check(b.state == S.SPOTTED, "still reacting before reaction time ends")
	_run_brain(b, 0.3, Vector2(200, 0))
	_check(b.state == S.THREAT, "after reaction time: threat (telegraph)")
	_run_brain(b, 0.7, Vector2(200, 0))
	_check(b.state == S.ATTACK, "after telegraph time: attack")
	var shot_seen := false
	for i in 30:
		b.see_player(Vector2(200, 0))
		if b.tick(0.05)["shoot"] != null:
			shot_seen = true
	_check(shot_seen, "attacking enemy fires")
	_run_brain(b, 2.5)
	_check(b.state == S.INVESTIGATE or b.state == S.IDLE, "lost the target: searches then calms")

	b = _new_brain(E)
	b.see_player(Vector2(200, 0))
	b.tick(0.05)
	_run_brain(b, 3.6)
	_check(b.state == S.INVESTIGATE or b.state == S.IDLE, "spotted but lost sight: aims at the last position, then investigates")

	var p := _brain_params()
	p["chance"] = {"weapon_drop": 0.0, "down": 0.0, "freeze": 0.0, "turn": 0.0}
	var rng := RandomNumberGenerator.new()
	b = NpcBrain.new(E, p, rng, false)
	b.see_player(Vector2(100, 0))
	b.tick(0.05)
	_check(b.on_command(NpcBrain.Cmd.WEAPON_DROP) == "refuse" and b.state == S.SPOTTED, "zero compliance chance: enemy refuses")
	var complied := false
	for seed_value in 40:
		b = _new_brain(E, "normal", false, seed_value)
		b.see_player(Vector2(100, 0))
		b.tick(0.05)
		_run_brain(b, 0.8, Vector2(100, 0))
		p = _brain_params()
		if b.on_command(NpcBrain.Cmd.TURN) == "comply":
			complied = true
			break
	_check(complied and b.state == S.SURRENDER and not b.armed, "enemy can comply: surrenders and drops the weapon")
	_check(b.restrainable() and b.restrain() and b.state == S.RESTRAINED, "disarmed surrendered enemy can be restrained")

	var feigner := _new_brain(E, "normal", true)
	feigner.see_player(Vector2(100, 0))
	feigner.tick(0.05)
	feigner.on_threat_shot()
	for seed_value in 60:
		if feigner.state == S.SURRENDER:
			break
		feigner = _new_brain(E, "normal", true, seed_value)
		feigner.see_player(Vector2(100, 0))
		feigner.tick(0.05)
		feigner.on_threat_shot()
	_check(feigner.state == S.SURRENDER and feigner.feigning and feigner.armed, "feigning enemy: surrender pose but still armed")
	_check(not feigner.restrainable(), "cannot restrain someone who is faking surrender")
	_run_brain(feigner, 2.2)
	_check(feigner.state == S.THREAT and feigner.armed, "fake surrender ends with a threat telegraph")
	_run_brain(feigner, 0.7)
	_check(feigner.state == S.ATTACK, "then the attack follows")

	b = _new_brain(E)
	b.on_hit(0, true, Vector2.ZERO)
	_check(b.state == S.DOWN and not b.armed and b.restrainable(), "stunned enemy: down, disarmed, restrainable")
	_run_brain(b, 6.5)
	_check(b.state == S.SURRENDER and not b.armed, "after the stun: kneels unarmed")

	b = _new_brain(E)
	b.on_hit(2, false, Vector2(50, 0))
	_check(b.hp == 1 and b.state != S.DEAD, "damaged but alive")
	b.on_hit(2, false, Vector2(50, 0))
	_check(b.state == S.DEAD and not b.alive(), "enough damage kills")

	b = _new_brain(E)
	for i in 10:
		b.see_laser(Vector2(100, 0), Vector2(0, 0))
		b.tick(0.05)
	_check(b.state == S.IDLE and is_equal_approx(b.facing, 0.0), "short laser sight: only turns to look")
	_run_brain_laser(b, 2.5)
	_check(b.state == S.INVESTIGATE, "laser on them for long: investigates")

	p = _brain_params()
	p["threat_shot_surrender_chance"] = 1.0
	b = NpcBrain.new(E, p, RandomNumberGenerator.new(), false)
	b.see_player(Vector2(100, 0))
	b.tick(0.05)
	b.on_threat_shot()
	_check(b.state == S.SURRENDER and not b.armed, "warning shot can make a cornered enemy surrender")

	var C := NpcBrain.Role.CIVILIAN
	var civ := _new_brain(C)
	civ.hear("gunshot", Vector2(50, 0), 0.8)
	var cout := civ.tick(0.05)
	_check(civ.state == S.HIDE or civ.state == S.FLEE, "civilian panics at a gunshot")
	if civ.state == S.HIDE:
		_check(cout["scream"], "hiding civilian screams")
	civ = _new_brain(C)
	var ok := false
	for seed_value in 20:
		civ = _new_brain(C, "normal", false, seed_value)
		if civ.on_command(NpcBrain.Cmd.DOWN) == "comply":
			ok = true
			break
	_check(ok and civ.state == S.DOWN and civ.restrainable(), "civilian ordered down: lies down and can be restrained")


func _run_brain_laser(b: NpcBrain, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		b.see_laser(Vector2(100, 0), Vector2(0, 0))
		b.tick(0.05)
		t += 0.05


func _make_world(preset: String = "normal") -> Dictionary:
	var lv := Level.new()
	lv.load_map("res://data/map_01.json")
	root.add_child(lv)
	await physics_frame
	await physics_frame
	var players: Array[PlayerState] = []
	for s in 2:
		var ps := PlayerState.new()
		ps.pos = lv.spawns[s]
		players.append(ps)
	var d := NpcDirector.new(lv, _tuning(), _diff(preset), players, 1234)
	return {"level": lv, "players": players, "dir": d}


func _settle() -> void:
	for i in 3:
		await physics_frame


func _free_world(w: Dictionary) -> void:
	var lv: Level = w["level"]
	root.remove_child(lv)
	lv.free()


func _test_level_doors() -> void:
	var lv := Level.new()
	lv.load_map("res://data/map_01.json")
	root.add_child(lv)
	await physics_frame
	await physics_frame

	# door A (index 0): [380,430,80,20] horizontal; ajar leaves a 12px slit at x 448..460
	_check(not lv.has_los(Vector2(454, 500), Vector2(454, 300)), "closed door: no sight through the slit position")
	lv.set_door_state(0, Level.DoorState.AJAR, 1)
	await _settle()
	_check(lv.has_los(Vector2(454, 500), Vector2(454, 300)), "ajar door: sight passes through the slit")
	_check(not lv.has_los(Vector2(420, 500), Vector2(420, 300)), "ajar door: still blocks sight elsewhere")
	var poly := lv.visibility_polygon(Vector2(454, 500), 700.0)
	_check(_min_y(poly) < 430.0, "ajar door: fog polygon shows a sliver of the room")

	var body := CharacterBody2D.new()
	body.collision_layer = 2
	body.collision_mask = Level.WALL_LAYER
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.position = Vector2(454, 500)
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = PLAYER_R
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)
	for i in 40:
		body.velocity = Vector2(0, -220)
		body.move_and_slide()
		await physics_frame
	_check(body.position.y > 430.0, "a body cannot squeeze through an ajar door (y=%.1f)" % body.position.y)
	root.remove_child(body)
	body.free()

	_check(not lv.toggle_door(2, 1) and lv.get_door_state(2) == Level.DoorState.CLOSED, "locked door refuses a normal open")
	lv.set_locked(2, false)
	_check(lv.toggle_door(2, 2) and lv.get_door_state(2) == Level.DoorState.OPEN and lv.door_actor[2] == 2, "unlocked door opens and remembers the actor")

	var open_air := lv.blockers_between(Vector2(300, 500), Vector2(1300, 500))
	_check(int(open_air["walls"]) + int(open_air["closed"]) + int(open_air["ajar"]) == 0, "corridor: nothing between")
	var through_wall := lv.blockers_between(Vector2(300, 500), Vector2(300, 300))
	_check(int(through_wall["walls"]) == 1, "one wall between corridor and room A")
	var through_ajar := lv.blockers_between(Vector2(420, 500), Vector2(420, 300))
	_check(int(through_ajar["ajar"]) == 1, "ajar door counted separately")
	var through_door := lv.blockers_between(Vector2(820, 500), Vector2(820, 300))
	_check(int(through_door["closed"]) == 1, "closed door counted")

	_check(lv.is_dark(Vector2(800, 300)) and not lv.is_dark(Vector2(400, 300)) and not lv.is_dark(Vector2(700, 500)), "room lighting flags")
	_check(not lv.find_path(Vector2(400, 500), Vector2(400, 300)).is_empty(), "path from corridor to room A through its door")
	lv.set_locked(2, true)
	lv.set_door_state(2, Level.DoorState.CLOSED, 0)
	_check(lv.find_path(Vector2(1220, 500), Vector2(1200, 300)).is_empty(), "locked door: no path into room C")
	lv.set_locked(2, false)
	_check(not lv.find_path(Vector2(1220, 500), Vector2(1200, 300)).is_empty(), "unlocked: path appears")

	var packed := lv.pack_doors()
	var lv2 := Level.new()
	lv2.load_map("res://data/map_01.json")
	lv2.unpack_doors(packed)
	_check(lv2.get_door_state(0) == Level.DoorState.AJAR and lv2.door_actor[0] == 1 and not lv2.is_locked(2) and lv2.is_locked(3), "door states, actors and locks survive packing")
	_check(lv.door_cam_origin(1, Vector2(820, 500)).y < 430.0 and lv.door_cam_origin(1, Vector2(820, 300)).y > 450.0, "door camera sits on the far side of the door")
	lv2.free()
	root.remove_child(lv)
	lv.free()


func _test_director() -> void:
	var S := NpcBrain.State

	# a kick in the corridor is heard through the closed door of room B
	var w := await _make_world()
	var d: NpcDirector = w["dir"]
	var lv: Level = w["level"]
	d.on_sound(SoundProp.Kind.KICK, Vector2(820, 500), -1)
	d.tick(0.1)
	_check(d.agents[0].brain.state == S.INVESTIGATE, "enemy hears a kick through a closed door")
	for i in 60:
		d.tick(0.1)
		await physics_frame
	_check(lv.get_door_state(1) == Level.DoorState.OPEN, "investigating enemy opens the door on the way")
	_free_world(w)

	w = await _make_world()
	d = w["dir"]
	d.on_sound(SoundProp.Kind.FOOTSTEP, Vector2(820, 500), -1)
	d.tick(0.1)
	_check(d.agents[0].brain.state == S.IDLE, "a footstep is too quiet to cross a door")
	_free_world(w)

	# open door + clear line: spot, threaten, attack
	w = await _make_world()
	d = w["dir"]
	lv = w["level"]
	var players: Array[PlayerState] = w["players"]
	var counters := [0, 0]
	d.shot.connect(func(_n: int, _a: Vector2, _b: Vector2) -> void: counters[0] += 1)
	d.player_hit.connect(func(_s: int, _n: int) -> void: counters[1] += 1)
	lv.set_door_state(1, Level.DoorState.OPEN, 1)
	await _settle()
	players[0].pos = Vector2(800, 480)
	players[1].pos = Vector2(100, 480)
	var seen_states := {}
	for i in 40:
		d.tick(0.1)
		seen_states[d.agents[0].brain.state] = true
		await physics_frame
	_check(seen_states.has(S.SPOTTED) and seen_states.has(S.THREAT) and seen_states.has(S.ATTACK), "enemy goes spotted -> threat -> attack (%s)" % str(seen_states.keys()))
	_check(counters[0] >= 1, "attacking enemy actually fires")
	_free_world(w)

	# closed door: no sight, no reaction
	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	players[0].pos = Vector2(800, 480)
	players[1].pos = Vector2(100, 480)
	for i in 20:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[0].brain.state == S.IDLE, "closed door hides the player from the enemy")
	_free_world(w)

	# dark room: detection range shrinks unless a flashlight is on
	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	d.agents[0].pos = Vector2(800, 200)
	d.agents[0].home = Vector2(800, 200)
	d.agents[0].brain.facing = PI / 2.0
	players[0].pos = Vector2(800, 350)
	players[1].pos = Vector2(100, 480)
	for i in 5:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[0].brain.state == S.IDLE, "dark room: enemy does not see a player 150px away")
	players[0].flash = true
	players[0].aim = -PI / 2.0
	for i in 5:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[0].brain.state == S.SPOTTED or d.agents[0].brain.state == S.THREAT, "flashlight on: the player is seen at 150px")
	_free_world(w)

	# laser dot on the wall the enemy faces
	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	d.agents[0].pos = Vector2(800, 200)
	d.agents[0].home = Vector2(800, 200)
	d.agents[0].brain.facing = 0.0
	players[0].pos = Vector2(640, 200)
	players[0].aim = 0.0
	players[0].laser = true
	players[1].pos = Vector2(100, 480)
	d.agents[0].brain.facing = 0.0
	var turned := false
	for i in 8:
		d.tick(0.1)
		await physics_frame
	turned = d.agents[0].brain.state == S.SPOTTED or d.agents[0].brain.state == S.THREAT or d.agents[0].brain.state == S.IDLE
	_check(turned, "laser near an enemy does not instantly reveal the shooter")
	_free_world(w)

	# commands, restraint, shots
	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	players[0].pos = Vector2(400, 400)
	players[0].aim = -PI / 2.0
	players[1].pos = Vector2(100, 480)
	var res := d.command(0, NpcBrain.Cmd.TURN)
	_check(int(res["target"]) == 2, "command goes to the civilian in the aim cone")
	players[0].aim = 0.0
	_check(int(d.command(0, NpcBrain.Cmd.TURN)["target"]) == -1, "command with nobody in the cone goes nowhere")
	players[0].aim = -PI / 2.0
	var tries := 0
	while d.agents[2].brain.state != S.SURRENDER and tries < 30:
		d.agents[2].brain.state = S.IDLE
		d.command(0, NpcBrain.Cmd.TURN)
		tries += 1
	_check(d.agents[2].brain.state == S.SURRENDER, "civilian surrenders on command")
	_check(d.restrain_candidate(Vector2(400, 330)) == 2 and d.restrain_candidate(Vector2(400, 420)) == -1, "restraint needs to be next to the target")
	_check(d.restrain(2) and d.agents[2].brain.state == S.RESTRAINED, "restraint works on a surrendered civilian")

	var shot := d.resolve_player_shot(0, Vector2(300, 330), Vector2(500, 330), 2, false)
	_check(int(shot["npc"]) == -1, "a shot passing 30px from a civilian does not hit")
	_check(d.agents[3].brain.state == S.IDLE, "other room's civilian unaffected")

	d.agents[0].pos = Vector2(800, 300)
	var hit := d.resolve_player_shot(0, Vector2(800, 400), Vector2(800, 200), 0, true)
	_check(int(hit["npc"]) == 0 and d.agents[0].brain.state == S.DOWN and not d.agents[0].brain.armed, "non-lethal round stuns and disarms")
	_check(d.restrain_candidate(Vector2(800, 330)) == 0, "stunned enemy can be restrained")
	hit = d.resolve_player_shot(0, Vector2(400, 400), Vector2(400, 200), 2, false)
	_check(int(hit["npc"]) == 2 and d.count_state(NpcBrain.Role.CIVILIAN, S.DEAD) == 1, "shooting a restrained civilian kills them (counted)")
	_free_world(w)

	# warning shot near an unaware civilian makes them hide
	w = await _make_world()
	d = w["dir"]
	d.resolve_player_shot(0, Vector2(300, 330), Vector2(500, 330), 1, false)
	_check(d.agents[2].brain.state == S.HIDE, "warning shot: civilian hides")
	_free_world(w)

	# alert sharing respects distance and walls
	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	d.agents[1].pos = Vector2(900, 300)
	d.agents[1].home = Vector2(900, 300)
	players[0].pos = Vector2(800, 380)
	players[1].pos = Vector2(100, 480)
	d.agents[0].brain.facing = PI / 2.0
	for i in 4:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[1].brain.state == S.INVESTIGATE or d.agents[1].brain.is_alert(), "a nearby ally in the same room is alerted")
	_free_world(w)

	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	players[0].pos = Vector2(800, 380)
	players[1].pos = Vector2(100, 480)
	d.agents[0].brain.facing = PI / 2.0
	for i in 4:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[1].brain.state == S.IDLE, "a distant enemy in another room is not alerted")

	var other: NpcDirector = NpcDirector.new(w["level"], _tuning(), _diff(), players, 99)
	var pk := d.pack()
	other.unpack(pk[0], pk[1], pk[2])
	_check(other.agents[0].pos == d.agents[0].pos and other.agents[0].brain.state == d.agents[0].brain.state and other.agents[3].brain.hp == d.agents[3].brain.hp, "NPC pack/unpack roundtrip")
	_free_world(w)


func _min_y(poly: PackedVector2Array) -> float:
	var m := INF
	for p in poly:
		m = minf(m, p.y)
	return m


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failed += 1


func _test_classify_ip() -> void:
	var expect := {
		"203.0.113.5": "public", "8.8.8.8": "public", "100.63.0.1": "public", "100.128.0.1": "public",
		"192.168.0.1": "private", "10.1.2.3": "private", "172.16.0.1": "private", "172.31.9.9": "private",
		"172.32.0.1": "public", "127.0.0.1": "private", "169.254.1.1": "private",
		"100.64.0.1": "cgnat", "100.127.255.255": "cgnat",
		"": "invalid", "1.2.3": "invalid", "300.1.1.1": "invalid", "a.b.c.d": "invalid",
	}
	for ip in expect:
		_check(UpnpHelper.classify_ip(ip) == expect[ip], "classify_ip '%s' -> %s" % [ip, expect[ip]])


func _test_room_code() -> void:
	var cases := [["100.64.0.1", 24565], ["127.0.0.1", 1], ["255.255.255.255", 65535], ["0.0.0.0", 80]]
	for c in cases:
		var code := RoomCode.encode(c[0], c[1])
		_check(code.length() == 14, "encode format %s:%d -> %s" % [c[0], c[1], code])
		var d := RoomCode.decode(code)
		_check(d.ok and d.ip == c[0] and d.port == c[1], "roundtrip %s:%d" % [c[0], c[1]])

	var code := RoomCode.encode("100.101.102.103", 24565)
	var lower := code.to_lower().replace("-", "")
	_check(RoomCode.decode(lower).ok, "decode ignores case and hyphens")
	_check(RoomCode.decode(" " + code + " ").ok, "decode ignores spaces")

	var undetected := 0
	var raw := code.replace("-", "")
	for i in raw.length():
		for ch in RoomCode.ALPHABET:
			if ch == raw[i]:
				continue
			var bad := raw.substr(0, i) + ch + raw.substr(i + 1)
			if RoomCode.decode(bad).ok:
				undetected += 1
	_check(undetected == 0, "every single-char typo is rejected (undetected=%d)" % undetected)

	_check(not RoomCode.decode("").ok, "empty code rejected")
	_check(not RoomCode.decode("ABCD-EFGH").ok, "short code rejected")
	_check(not RoomCode.decode("UUUU-UUUU-UUUU").ok, "invalid chars rejected")
	_check(RoomCode.encode("256.1.1.1", 80) == "", "bad octet rejected")
	_check(RoomCode.encode("1.2.3", 80) == "", "bad ip shape rejected")
	_check(RoomCode.encode("1.2.3.4", 0) == "", "port 0 rejected")
	_check(RoomCode.encode("1.2.3.4", 65536) == "", "port 65536 rejected")

	var addrs := PackedStringArray(["192.168.0.5", "fe80::1", "100.63.1.1", "100.100.5.9", "100.128.0.1"])
	_check(RoomCode.pick_vlan_ip(addrs) == "100.100.5.9", "pick_vlan_ip picks 100.64/10 only")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["10.0.0.2"])) == "", "pick_vlan_ip empty when none")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["192.168.45.79", "26.215.124.50"])) == "26.215.124.50", "pick_vlan_ip finds Radmin 26.x")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["25.1.2.3"])) == "25.1.2.3", "pick_vlan_ip finds Hamachi 25.x")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["26.1.1.1", "100.100.5.9", "25.1.1.1"])) == "100.100.5.9", "Tailscale preferred over Radmin/Hamachi")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["25.1.1.1", "26.1.1.1"])) == "26.1.1.1", "Radmin preferred over Hamachi")
	_check(RoomCode.vlan_kind("27.0.0.1") == "" and RoomCode.vlan_kind("x.y") == "", "vlan_kind ignores other ranges")
