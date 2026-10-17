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
	_test_mission()
	_test_clock_and_vote()
	_test_sfx()
	_test_audition_model()
	await _test_level()
	await _test_props()
	await _test_cover()
	await _test_tactics()
	await _test_level_doors()
	await _test_director()
	print("---- %s" % ("FAILED: %d" % _failed if _failed > 0 else "ALL PASSED"))
	quit(1 if _failed > 0 else 0)


## The take-picking tool's data: takes ordered by score, decisions kept, _pick copies in step.
func _test_audition_model() -> void:
	var root := ProjectSettings.globalize_path("user://audition_test")
	DirAccess.make_dir_recursive_absolute(root.path_join("_raw/rifle"))
	DirAccess.make_dir_recursive_absolute(root.path_join("_raw/door"))
	for f in ["rifle_s1.wav", "rifle_s2.wav", "rifle_s3.wav"]:
		var w := FileAccess.open(root.path_join("_raw/rifle").path_join(f), FileAccess.WRITE)
		w.store_string("fake " + f)
	FileAccess.open(root.path_join("_raw/door/door_s1.wav"), FileAccess.WRITE).store_string("fake door")
	FileAccess.open(root.path_join("_raw/rifle/ranking.json"), FileAccess.WRITE).store_string(JSON.stringify([
		{"file": "rifle_s2.wav", "score": 0.99, "onset_s": 0.07, "events": 1, "centroid_hz": 2900},
		{"file": "rifle_s1.wav", "score": 0.5, "onset_s": 0.4, "events": 1, "centroid_hz": 4000}]))
	var m := AuditionModel.new(root)
	m.load_all(["rifle", "missing", "door"])
	_check(m.keys == ["rifle", "door"], "audition: sounds follow the catalog order, missing ones are left out")
	var files: Array = m.takes["rifle"].map(func(t: Dictionary) -> String: return t["file"])
	_check(files == ["rifle_s2.wav", "rifle_s1.wav", "rifle_s3.wav"], "audition: takes are ordered best score first, unranked last")
	_check(m.counts("rifle") == {"use": 0, "skip": 0, "open": 3}, "audition: everything starts undecided")
	m.set_decision("rifle", "rifle_s2.wav", AuditionModel.USE)
	m.set_decision("rifle", "rifle_s1.wav", AuditionModel.SKIP)
	_check(FileAccess.file_exists(root.path_join("_pick/rifle/rifle_s2.wav")) and not FileAccess.file_exists(root.path_join("_pick/rifle/rifle_s1.wav")), "audition: a take marked use is copied to _pick, a skipped one is not")
	_check(m.counts("rifle") == {"use": 1, "skip": 1, "open": 1} and m.counts() == {"use": 1, "skip": 1, "open": 2}, "audition: counts per sound and overall")
	var again := AuditionModel.new(root)
	again.load_all(["rifle", "door"])
	_check(again.decision("rifle", "rifle_s2.wav") == AuditionModel.USE and again.decision("rifle", "rifle_s1.wav") == AuditionModel.SKIP, "audition: decisions survive a restart")
	again.set_decision("rifle", "rifle_s2.wav", "")
	_check(not FileAccess.file_exists(root.path_join("_pick/rifle/rifle_s2.wav")) and again.counts("rifle")["open"] == 2, "audition: clearing a decision removes the copy")
	for dir in ["_pick/rifle", "_pick", "_raw/rifle", "_raw/door", "_raw"]:
		for f in DirAccess.get_files_at(root.path_join(dir)):
			DirAccess.remove_absolute(root.path_join(dir).path_join(f))
		DirAccess.remove_absolute(root.path_join(dir))
	DirAccess.remove_absolute(root)


func _test_sfx() -> void:
	var t0 := Time.get_ticks_msec()
	var streams := {
		"rifle": SfxSynth.gunshot(1, true), "pistol": SfxSynth.gunshot(4, false), "footstep": SfxSynth.footstep(10),
		"door": SfxSynth.door(21, 0.6, 0.6), "kick": SfxSynth.kick(41), "taser": SfxSynth.taser(71),
		"shout": SfxSynth.shout(51, 100.0, 0.7, 0.5), "scream": SfxSynth.shout(61, 380.0, 0.9, 2.0),
		"siren": SfxSynth.siren(), "reload": SfxSynth.reload_sound(81), "hit": SfxSynth.hit(91), "hurt": SfxSynth.hurt(95),
		"ringing": SfxSynth.ringing(), "radio": SfxSynth.radio(97), "heart": SfxSynth.heart()}
	print("sfx synth: %d sounds in %d ms" % [streams.size(), Time.get_ticks_msec() - t0])
	for k in streams:
		var s: AudioStreamWAV = streams[k]
		var n := s.data.size() / 2
		var peak := 0
		for i in n:
			peak = maxi(peak, absi(s.data.decode_s16(i * 2)))
		_check(n > 1000 and peak > 8000 and peak <= 32767, "sfx %s has audible, unclipped samples" % k)
	_check((streams["rifle"] as AudioStreamWAV).data.size() > (streams["pistol"] as AudioStreamWAV).data.size(), "rifle shot rings longer than a pistol shot")
	var rifle: AudioStreamWAV = streams["rifle"]
	var tail := 0
	for i in range(int(0.3 * SfxSynth.RATE), int(0.6 * SfxSynth.RATE)):
		tail = maxi(tail, absi(rifle.data.decode_s16(i * 2)))
	_check(tail > 150, "rifle shot keeps a reverb tail 0.3-0.6 s after the bang")
	_check(SfxSynth.gunshot(1, true).data == SfxSynth.gunshot(1, true).data, "same seed gives identical samples")
	_check(SfxSynth.gunshot(1, true).data != SfxSynth.gunshot(2, true).data, "different seed gives a different shot")
	var hum := SfxSynth.hum()
	var count := hum.data.size() / 2
	_check(hum.loop_mode == AudioStreamWAV.LOOP_FORWARD and hum.loop_end == count, "hum loops over its whole length")
	var seam := absf(float(hum.data.decode_s16(0)) - float(hum.data.decode_s16((count - 1) * 2))) / 32768.0
	_check(seam < 0.1, "hum loop seam is continuous")


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


func _test_mission() -> void:
	var M := MissionState
	var m := M.new()
	var base := {"suspect_restrained": false, "suspect_dead": false, "civ_unrestrained_alive": 2,
			"enemies_pending": 2, "players_alive": 2, "players_in_exit": 0}
	_check(m.phase == M.Phase.BRIEFING, "mission starts in the briefing")
	_check(not m.evaluate(base), "briefing: nothing is evaluated")
	_check(m.mark_ready(0) and m.phase == M.Phase.BRIEFING, "one player ready: still briefing")
	_check(not m.mark_ready(0), "ready twice changes nothing")
	_check(m.mark_ready(1) and m.phase == M.Phase.ACTIVE, "both ready: mission active")
	_check(not m.evaluate(base), "nothing done yet: no change")

	var snap := base.duplicate()
	snap["civ_unrestrained_alive"] = 0
	_check(m.evaluate(snap) and m.objectives[1] and not m.objectives[0], "all civilians restrained completes that objective")
	snap["civ_unrestrained_alive"] = 1
	m.evaluate(snap)
	_check(not m.objectives[1], "objectives can become incomplete again (a civilian is loose)")
	snap = {"suspect_restrained": true, "suspect_dead": false, "civ_unrestrained_alive": 0,
			"enemies_pending": 0, "players_alive": 2, "players_in_exit": 1}
	m.evaluate(snap)
	_check(m.objectives[0] and m.objectives[1] and m.objectives[2] and not m.objectives[3] and m.status == M.Status.ACTIVE, "return objective needs everyone alive in the exit zone")
	snap["players_in_exit"] = 2
	_check(m.evaluate(snap) and m.status == M.Status.SUCCESS and m.phase == M.Phase.RESULT, "all objectives + both in exit zone: success")
	snap["suspect_dead"] = true
	_check(not m.evaluate(snap) and m.status == M.Status.SUCCESS, "a finished mission no longer changes")

	m = M.new()
	m.mark_ready(0)
	m.mark_ready(1)
	snap = {"suspect_restrained": true, "suspect_dead": false, "civ_unrestrained_alive": 0,
			"enemies_pending": 0, "players_alive": 1, "players_in_exit": 1}
	m.evaluate(snap)
	_check(m.status == M.Status.SUCCESS, "a lone survivor in the exit zone completes the mission")

	m = M.new()
	m.mark_ready(0)
	m.mark_ready(1)
	snap = base.duplicate()
	snap["suspect_dead"] = true
	m.evaluate(snap)
	_check(m.status == M.Status.FAILED and m.reason_key() == "suspect_killed", "suspect killed: failure with its reason")

	m = M.new()
	m.mark_ready(0)
	m.mark_ready(1)
	snap = base.duplicate()
	snap["players_alive"] = 0
	m.evaluate(snap)
	_check(m.status == M.Status.FAILED and m.reason_key() == "all_dead", "both players dead: failure")
	m = M.new()
	m.mark_ready(0)
	m.mark_ready(1)
	snap["suspect_dead"] = true
	m.evaluate(snap)
	_check(m.reason_key() == "suspect_killed", "when both apply, the suspect's death is the reported cause")

	m = M.new()
	m.mark_ready(0)
	m.mark_ready(1)
	m.civ_killed = 1
	snap = base.duplicate()
	snap["civ_unrestrained_alive"] = 1
	m.evaluate(snap)
	_check(m.status == M.Status.ACTIVE, "a civilian death alone never fails the mission")

	m.civ_killed = 2
	m.suspect_killed = 1
	m.enemy_killed = 3
	m.reason = 1
	var copy := M.new()
	copy.unpack(m.pack())
	_check(copy.pack() == m.pack() and copy.civ_killed == 2 and copy.enemy_killed == 3, "mission state pack/unpack roundtrip")

	var rules: Dictionary = JsonData.load_dict("res://data/score.json")
	var none := {"suspect_killed": 0, "civilian_killed": 0, "enemy_killed": 0, "player_dead": 0}
	_check(ScoreRules.compute(none, rules) == 100 and ScoreRules.grade(100, rules) == "A", "clean run: full score, grade A")
	var civ := none.duplicate()
	civ["civilian_killed"] = 1
	_check(ScoreRules.compute(civ, rules) == 70 and ScoreRules.grade(70, rules) == "C", "one civilian killed costs score")
	var susp := none.duplicate()
	susp["suspect_killed"] = 1
	_check(ScoreRules.compute(susp, rules) == 40, "killing the suspect costs more than a civilian")
	var free := none.duplicate()
	free["enemy_killed"] = 6
	free["player_dead"] = 2
	_check(ScoreRules.compute(free, rules) == 100, "enemy kills and player deaths cost nothing (open, 0)")
	civ["civilian_killed"] = 10
	_check(ScoreRules.compute(civ, rules) == 0 and ScoreRules.grade(0, rules) == "F", "score never goes below zero")
	var edges := {90: "A", 89: "B", 75: "B", 74: "C", 60: "C", 59: "D", 45: "D", 44: "E", 30: "E", 29: "F", 0: "F"}
	for k in edges:
		_check(ScoreRules.grade(k, rules) == edges[k], "grade boundary %d -> %s" % [k, edges[k]])
	var lines := ScoreRules.breakdown({"suspect_killed": 0, "civilian_killed": 1, "enemy_killed": 3, "player_dead": 0}, rules)
	_check(lines.size() == 2 and lines[0].contains("-30") and lines[1].contains("감점 없음"), "breakdown lists events, free ones marked")


func _tick_clock(c: ReinforcementClock, seconds: float, step: float = 0.1) -> Array:
	var events := []
	var t := 0.0
	while t < seconds:
		var e := c.tick(step)
		if e != "":
			events.append(e)
		t += step
	return events


func _test_clock_and_vote() -> void:
	var C := ReinforcementClock
	var c := C.new(30.0, 8.0, 2.0)
	_check(c.phase == C.Phase.WAITING and _tick_clock(c, 20.0).is_empty(), "no events while the delay runs")
	var ev := _tick_clock(c, 3.0)
	_check(ev == ["warning"] and c.phase == C.Phase.WARNED, "the warning comes first")
	_check(c.remaining >= 7.0 and c.remaining <= 8.0, "arrival is about min_warning seconds after the warning (%.1f)" % c.remaining)
	ev = _tick_clock(c, 9.0)
	_check(ev == ["arrive"] and c.phase == C.Phase.ARRIVED, "then the wave arrives, exactly once")
	_check(_tick_clock(c, 20.0).is_empty(), "no second wave")

	c = C.new(100.0, 8.0, 2.0)
	c.add_noise(8.0)
	_check(is_equal_approx(c.remaining, 92.0), "a loud noise pulls the arrival earlier")
	c.add_noise(1000.0)
	_check(c.remaining == 0.0, "noise cannot go below zero")
	ev = _tick_clock(c, 0.1)
	_check(ev == ["warning"] and is_equal_approx(c.remaining, 8.0), "even a huge noise still gives the warning first, with its full lead")
	c.add_noise(100.0)
	_check(c.remaining >= 2.0 - 0.001, "after the warning, noise never cuts the lead below the minimum (%.1f)" % c.remaining)
	var c2 := C.new(100.0, 8.0, 2.0)
	_tick_clock(c2, 93.0)
	c2.add_noise(-5.0)
	c2.add_noise(0.0)
	_check(c2.phase == C.Phase.WARNED, "zero or negative noise changes nothing")

	var V := VoteState
	var v := V.new(15.0, 2)
	var both: Array[bool] = [true, true]
	v.start(both, true)
	_check(v.outcome == V.Outcome.PENDING and v.round_no == 1, "vote starts pending")
	_check(v.cast(0, V.Choice.RETRY) and v.outcome == V.Outcome.PENDING, "one vote: still waiting")
	_check(not v.cast(0, V.Choice.LOBBY), "a vote cannot be changed")
	_check(v.cast(1, V.Choice.RETRY) and v.outcome == V.Outcome.RETRY, "both retry: retry")
	_check(not v.cast(1, V.Choice.RETRY), "no votes after the outcome")

	v.start(both, true)
	v.cast(0, V.Choice.LOBBY)
	v.cast(1, V.Choice.LOBBY)
	_check(v.outcome == V.Outcome.LOBBY, "both lobby: lobby")

	v.start(both, true)
	v.cast(0, V.Choice.RETRY)
	v.cast(1, V.Choice.LOBBY)
	_check(v.outcome == V.Outcome.PENDING and v.round_no == 2 and v.votes == [0, 0] and v.time_left == 15.0, "disagreement: one more round with fresh votes and a fresh timer")
	v.cast(0, V.Choice.RETRY)
	v.cast(1, V.Choice.RETRY)
	_check(v.outcome == V.Outcome.RETRY, "agree in the second round: retry")

	v.start(both, true)
	v.cast(0, V.Choice.RETRY)
	v.cast(1, V.Choice.LOBBY)
	v.cast(0, V.Choice.LOBBY)
	v.cast(1, V.Choice.RETRY)
	_check(v.outcome == V.Outcome.LOBBY, "still different after the extra round: lobby")

	v.start(both, true)
	_check(not v.tick(14.0) and v.round_no == 1, "timer running")
	_check(v.tick(1.5) and v.round_no == 2 and v.outcome == V.Outcome.PENDING, "timeout with no votes: second round")
	v.cast(0, V.Choice.RETRY)
	_check(v.tick(16.0) and v.outcome == V.Outcome.LOBBY, "timeout again (only one voted): lobby")

	v.start(both, true)
	v.cast(0, V.Choice.RETRY)
	v.cast(1, V.Choice.RETRY)
	_check(not v.tick(30.0), "a finished vote ignores the timer")

	var solo_players: Array[bool] = [true, false]
	v.start(solo_players, false)
	_check(not v.cast(1, V.Choice.RETRY), "an absent player cannot vote")
	_check(not v.tick(100.0) and v.outcome == V.Outcome.PENDING, "solo vote has no timer")
	_check(v.cast(0, V.Choice.LOBBY) and v.outcome == V.Outcome.LOBBY, "solo: one vote decides")

	v.start(both, true)
	v.cast(0, V.Choice.RETRY)
	v.tick(3.0)
	var copy := V.new()
	copy.unpack(v.pack())
	_check(copy.pack() == v.pack() and copy.votes[0] == V.Choice.RETRY, "vote state pack/unpack roundtrip")

	var m := MissionState.new()
	m.reinforce = 2
	var mc := MissionState.new()
	mc.unpack(m.pack())
	_check(mc.reinforce == 2, "mission state carries the reinforcement phase")


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
	var cast_in := lv._vis_frame
	await physics_frame
	_check(lv.visibility_polygon(a, 700.0) == poly_closed and lv._vis_frame == cast_in, "standing still: the fog polygon is reused, not cast again")
	lv.toggle_door(1, 1)
	lv.visibility_polygon(a, 700.0)  # same frame as the change: the physics space has not caught up yet
	await physics_frame
	await physics_frame
	_check(_min_y(lv.visibility_polygon(a, 700.0)) < 430.0, "after a door opens the fog polygon is cast again (not served stale)")
	lv.toggle_door(1, 2)
	await physics_frame
	await physics_frame

	var near := lv.nearest_door(Vector2(150, 480), 80.0)
	_check(near == 5, "entrance door is nearest from the spawn")
	_check(lv.nearest_door(Vector2(700, 500), 30.0) == -1, "no door in range in mid corridor")
	lv.toggle_door(4, 1)
	var packed := lv.pack_doors()
	var lv2 := Level.new()
	lv2.load_map("res://data/map_01.json")
	lv2.unpack_doors(packed)
	_check(lv2.is_door_open(4) and not lv2.is_door_open(1) and lv2.door_actor[4] == 1, "door state pack/unpack")
	lv2.free()  # never in the tree: freed by hand or its bodies leak at exit

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


## Furniture stops bodies (its own physics layer) and NPC paths but not rays; rooms and the ground
## outside carry the surface styles the 3D view paints.
func _test_props() -> void:
	var lv := Level.new()
	lv.load_map("res://data/map_01.json")
	root.add_child(lv)
	await physics_frame
	await physics_frame
	var solid := lv.props.filter(func(p: Dictionary) -> bool: return p["solid"])
	_check(lv.props.size() > 40 and solid.size() > 30 and lv.props.any(func(p: Dictionary) -> bool: return p["kind"] == "rug" and not p["solid"]),
			"map furniture loads; rugs stop nobody")
	_check(str(lv.rooms[0]["floor"]) == "wood" and str(lv.rooms[0]["wall"]) == "warm" and lv.ground.size() >= 3, "rooms and the ground outside carry surface styles")
	_check(lv.room_style(Vector2(400, 300), "floor") == "wood" and lv.room_style(Vector2(100, 100), "floor") == "", "room_style: the room's style, none outside")
	var bed: Rect2 = (lv.props.filter(func(p: Dictionary) -> bool: return p["kind"] == "bed")[0] as Dictionary)["rect"]
	var y := bed.position.y + 50.0
	_check(lv.has_los(Vector2(bed.position.x - 30, y), Vector2(bed.end.x + 30, y)), "sight and shots pass over furniture")
	var path := lv.find_path(Vector2(bed.position.x - 40, y), Vector2(bed.end.x + 40, y))
	var through := false
	for p in path:
		through = through or bed.grow(4.0).has_point(p)
	_check(not path.is_empty() and not through, "NPC paths go round furniture")
	var body := CharacterBody2D.new()
	body.collision_layer = 2
	body.collision_mask = Level.WALL_LAYER | Level.PROP_LAYER
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.position = Vector2(bed.position.x - 40, y)
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = PLAYER_R
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)
	for i in 30:
		body.velocity = Vector2(220, 0)
		body.move_and_slide()
		await physics_frame
	_check(body.position.x <= bed.position.x - PLAYER_R + 1.0, "an officer cannot walk through the bed (x=%.1f)" % body.position.x)
	root.remove_child(body)
	body.free()
	root.remove_child(lv)
	lv.free()


## Cover: tall furniture stops sight and shots like a wall; low furniture catches some of the shots
## at someone close behind it (more when crouched, fewer with rounds that go through); enemies under
## fire run behind furniture, away from the officer.
func _test_cover() -> void:
	var w := await _make_world()
	var d: NpcDirector = w["dir"]
	var lv: Level = w["level"]
	var players: Array[PlayerState] = w["players"]
	var find := func(kind: String) -> Dictionary: return lv.props.filter(func(p: Dictionary) -> bool: return p["kind"] == kind)[0]
	var wardrobe: Rect2 = find.call("wardrobe")["rect"]
	var y := wardrobe.get_center().y
	_check(str(find.call("wardrobe")["cover"]) == "full" and not lv.has_los(Vector2(wardrobe.end.x + 30, y), Vector2(wardrobe.position.x - 1, y))
			and not lv.has_los(Vector2(wardrobe.end.x + 30, y), Vector2(wardrobe.position.x + 2, y)), "a wardrobe blocks sight and shots like a wall")
	var sofa: Rect2 = find.call("sofa")["rect"]
	var across := lv.cover_between(Vector2(sofa.get_center().x, sofa.end.y + 80), Vector2(sofa.get_center().x, sofa.position.y - 10))
	_check(across.size() == 1 and str(across[0]["cover"]) == "soft" and absf((across[0]["enter"] as Vector2).y - sofa.end.y) < 0.5,
			"a shot across the sofa crosses soft cover, entering at its front")
	_check(lv.cover_between(Vector2(sofa.get_center().x, sofa.end.y + 5), Vector2(sofa.get_center().x, sofa.position.y - 10)).is_empty(),
			"leaning on cover, the shooter fires over it")
	# someone crouched right behind the kitchen counter: some shots are caught, fewer with FMJ than JHP
	var counter: Rect2 = find.call("counter")["rect"]
	var a: NpcDirector.Agent = d.agents[0]
	var behind := Vector2(counter.get_center().x, counter.end.y + 4.0)  # tucked behind it (south side)
	var from := Vector2(counter.get_center().x, counter.position.y - 200.0)
	var caught := {"fmj": 0, "jhp": 0}
	for ammo: String in caught:
		for k in 200:
			a.pos = behind
			a.brain.state = S_HIDE
			a.brain.hp = 99
			var res := d.resolve_player_shot(0, from, behind + Vector2(0, 40), 0, false, _tuning()["ammo"][ammo]["cover"])
			if int(res["cover"]) >= 0:
				caught[ammo] += 1
	_check(caught["fmj"] > 40 and caught["jhp"] > caught["fmj"] + 20 and caught["jhp"] < 200, "low cover catches some shots; FMJ goes through more often (%s)" % caught)
	# an enemy shot at in the open in the kitchen runs behind the island counter, the counter between
	# it and the officer
	var island: Rect2 = find.call("island")["rect"]
	var e: NpcDirector.Agent = d.agents[0]
	e.pos = Vector2(island.end.x + 30, island.position.y - 30)
	e.brain.pos = e.pos
	e.brain.state = NpcBrain.State.ATTACK
	e.brain.armed = true
	players[0].pos = Vector2(island.get_center().x, island.position.y - 90)
	players[0].flash = true  # the kitchen is dark: the light keeps the officer seen from behind the counter
	players[1].pos = Vector2(100, 480)
	e.brain.target_pos = players[0].pos
	var spot := d._pick_cover(e)
	_check(spot != Vector2.INF and spot.distance_to(players[0].pos) > 90.0 and Geom2D.segment_hits_rect(players[0].pos, spot, island),
			"an enemy under fire finds a spot with the counter between it and the officer (%s)" % spot)
	_check(spot != Vector2.INF and not lv.find_path(e.pos, spot).is_empty(), "the cover spot can be reached")
	e.brain.cover_target = Vector2.INF
	e.brain.needs_cover = true
	for i in 30:
		d.tick(0.1)
		await physics_frame
	_check(e.brain.in_cover and e.pos.distance_to(spot) < 30.0 and e.brain.state == NpcBrain.State.ATTACK,
			"the enemy runs there, crouches and keeps watching the officer (in cover at %s, state %d)" % [e.pos, e.brain.state])
	_free_world(w)


## Enemy tactics: alert enemies react faster, aim settles and suffers from moving targets and
## suppression, a lost officer's spot is held, sounds from another room set up an ambush at a spot
## covering the way in, hurt enemies fall back once.
func _test_tactics() -> void:
	var E := NpcBrain.Role.ENEMY
	var S := NpcBrain.State
	var p := _brain_params()
	# alertness: a gunshot heard earlier makes the reaction to a sighting quicker
	var calm := _new_brain(E)
	var keyed := _new_brain(E)
	keyed.hear("gunshot", Vector2(400, 0), 0.3, false)
	keyed.tick(0.05)
	keyed.state = S.IDLE  # (heard it, calmed back to idle, still keyed up)
	var times := []
	for b: NpcBrain in [calm, keyed]:
		var t := 0.0
		while b.state != S.THREAT and t < 3.0:
			b.see_player(Vector2(200, 0))
			b.tick(0.05)
			t += 0.05
		times.append(t)
	_check(keyed.alertness > 0.9 and times[1] < times[0] - 0.15, "a keyed-up enemy (heard a shot) raises its gun sooner (%.2f s vs %.2f s)" % [times[1], times[0]])
	var fading := _new_brain(E)
	fading.hear("gunshot", Vector2(400, 0), 0.3)
	fading.tick(0.05)
	fading.state = S.IDLE
	_run_brain(fading, float(p["alert_decay_s"]) * 0.5)
	_check(fading.alertness > 0.3 and fading.alertness < 0.7, "alertness fades over alert_decay_s (%.2f after half)" % fading.alertness)
	# aim: poor at the first snap, steady after aim_settle_s, worse under fire
	var aim := _new_brain(E)
	var first := aim.aim_quality()
	_run_brain(aim, float(p["aim_settle_s"]) + 0.1, Vector2(200, 0))
	var steady := aim.aim_quality()
	aim.on_threat_shot()
	_check(is_equal_approx(first, float(p["aim_first_mult"])) and is_equal_approx(steady, float(p["aim_steady_mult"]))
			and is_equal_approx(aim.aim_quality(), steady * float(p["aim_suppressed_mult"])),
			"aim: %.2f at the first shot, %.2f once settled, less while being shot at" % [first, steady])
	# ambush: a sound from another room, a sound in its own room
	var amb := 0
	var walk := 0
	for seed_value in 40:
		var b := _new_brain(E, "normal", false, seed_value)
		b.hear("door", Vector2(400, 0), 0.5, true)
		b.tick(0.05)
		if b.needs_ambush:
			amb += 1
		var same := _new_brain(E, "normal", false, seed_value)
		same.hear("door", Vector2(400, 0), 0.5, false)
		same.tick(0.05)
		if not same.needs_ambush and same.state == S.INVESTIGATE:
			walk += 1
	_check(amb > 8 and amb < 32 and walk == 40, "a sound from another room: some wait in ambush (%d/40), from its own room all go and look" % amb)
	var ab := _new_brain(E)
	p = _brain_params()
	p["ambush_chance"] = 1.0
	ab = NpcBrain.new(E, p, RandomNumberGenerator.new(), false)
	ab.hear("door", Vector2(400, 0), 0.5, true)
	ab.tick(0.05)
	ab.set_ambush(Vector2(50, 50), Vector2(300, 50))
	var out := ab.tick(0.05)
	_check(ab.state == S.INVESTIGATE and out["move_to"] == Vector2(50, 50) and out["run"] and ab.aiming, "ambush: runs to its spot, gun up")
	ab.pos = Vector2(50, 50)
	ab.arrived()
	out = ab.tick(0.05)
	_check(out["move_to"] == null and absf(angle_difference(ab.facing, 0.0)) < 0.01 and ab.aiming, "ambush: waits there covering the way in")
	_run_brain(ab, float((p["ambush_s"] as Array)[1]) + 0.2)
	out = ab.tick(0.05)
	_check(ab.state == S.INVESTIGATE and not ab.aiming and out["move_to"] == Vector2(400, 0), "nobody came: leaves the ambush and goes to look")
	var sb := NpcBrain.new(E, p, RandomNumberGenerator.new(), false)
	sb.hear("door", Vector2(400, 0), 0.5, true)
	sb.tick(0.05)
	sb.set_ambush(Vector2.INF, Vector2(300, 0))
	sb.see_player(Vector2(300, 0))
	sb.tick(0.05)
	_check(sb.state == S.SPOTTED, "an officer coming through the door is spotted from the ambush")
	# retreat: hurt but armed, it falls back once
	p = _brain_params()
	p["hurt_surrender_chance"] = 0.0
	p["retreat_chance"] = 1.0
	var rb := NpcBrain.new(E, p, RandomNumberGenerator.new(), false)
	rb.see_player(Vector2(200, 0))
	_run_brain(rb, 1.4, Vector2(200, 0))
	rb.on_hit(2, false, Vector2(200, 0))
	_check(rb.state == S.FLEE and rb.armed and rb.needs_flee_target, "hurt and still armed: falls back")
	rb.state = S.ATTACK
	rb.on_hit(0, false, Vector2(200, 0))
	rb.hp = 2
	rb.on_hit(1, false, Vector2(200, 0))
	_check(rb.state == S.ATTACK, "it falls back only once, then fights on")
	# the director: an ambush spot in room B that sees the door to the corridor, behind cover if any
	var w := await _make_world()
	var d: NpcDirector = w["dir"]
	var lv: Level = w["level"]
	d._params["ambush_chance"] = 1.0
	var e: NpcDirector.Agent = d.agents[0]  # in room B
	d.on_sound(SoundProp.Kind.KICK, Vector2(820, 500), -1)
	d.tick(0.1)
	d.tick(0.1)  # the brain asks for a spot, the director answers on the next tick
	var spot := e.brain.ambush_spot
	var look := e.brain.ambush_look
	_check(e.brain.state == S.INVESTIGATE and look != Vector2.INF and lv.room_at(look) == lv.room_at(e.pos)
			and (spot == Vector2.INF or (lv.room_at(spot) == lv.room_at(e.pos) and lv.has_los(spot, look))),
			"the ambush covers the doorway from inside its room (spot %s, door %s)" % [spot, look])
	for i in 40:
		d.tick(0.1)
		await physics_frame
	_check(lv.get_door_state(1) != Level.DoorState.OPEN and e.brain.aiming, "in ambush it does not open the door: it waits for it to open")
	_free_world(w)
	# a moving officer is harder to hit
	w = await _make_world()
	d = w["dir"]
	var pls: Array[PlayerState] = w["players"]
	for i in 10:
		pls[0].pos += Vector2(22.0, 0.0)  # 220 px/s at 0.1 s
		d.tick(0.1)
	var moving := d.moving_target_mult(0)
	for i in 30:
		d.tick(0.1)
	_check(moving < 0.75 and is_equal_approx(d.moving_target_mult(0), 1.0) or d.moving_target_mult(0) > 0.98,
			"a running officer is harder to hit (x%.2f), a still one is not (x%.2f)" % [moving, d.moving_target_mult(0)])
	_free_world(w)


const S_HIDE := NpcBrain.State.HIDE


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
	_check(b.state == S.ATTACK and b.aiming and absf(angle_difference(b.facing, 0.0)) < 0.01,
			"lost the target: first keeps aiming at where the officer was (holding the angle)")
	var hold_max: float = (_brain_params()["hold_s"] as Array)[1]
	_run_brain(b, hold_max)
	_check(b.state == S.INVESTIGATE or b.state == S.IDLE, "nobody came back: then searches and calms")

	b = _new_brain(E)
	b.see_player(Vector2(200, 0))
	b.tick(0.05)
	_run_brain(b, 3.6 + hold_max)
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
	d._params["ambush_chance"] = 0.0  # (the brains share these): this one walks to the sound
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

	# the suspect: both clues, decoys carry only one
	w = await _make_world()
	d = w["dir"]
	var suspects := 0
	for a in d.agents:
		if a.suspect:
			suspects += 1
	_check(suspects == 1 and d.agents[4].suspect, "exactly one designated suspect")
	_check(d.agents[4].clues.has("cap") and d.agents[4].clues.has("band"), "the suspect shows both clues")
	_check(d.agents[0].clues.size() == 1 and d.agents[3].clues.size() == 1 and d.agents[0].clues != d.agents[3].clues, "decoys each show a single, different clue")
	var kills := []
	d.npc_killed.connect(func(n: int, s: int) -> void: kills.append([n, s]))
	d.resolve_player_shot(0, Vector2(1100, 300), Vector2(1300, 300), 99, false)
	_check(kills.size() == 1 and kills[0][0] == 4, "killing the suspect is reported")
	d.resolve_player_shot(0, Vector2(1100, 300), Vector2(1300, 300), 99, false)
	_check(kills.size() == 1, "shooting a corpse reports nothing more")
	d.resolve_player_shot(1, Vector2(400, 400), Vector2(400, 200), 0, true)
	_check(kills.size() == 1, "a non-lethal round never reports a kill")
	_free_world(w)

	# reinforcements stay out of play until they arrive
	w = await _make_world()
	d = w["dir"]
	players = w["players"]
	var dormant := []
	for i in d.agents.size():
		if d.agents[i].dormant:
			dormant.append(i)
	_check(dormant == [5, 6], "two reinforcement agents wait outside, dormant")
	var start_pos: Vector2 = d.agents[5].pos
	d.on_sound(SoundProp.Kind.KICK, Vector2(120, 300), -1)
	players[0].pos = Vector2(120, 300)
	for i in 5:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[5].pos == start_pos and d.agents[5].brain.state == S.IDLE, "a dormant agent neither hears nor moves")
	var shot_res := d.resolve_player_shot(0, Vector2(30, 280), Vector2(200, 280), 99, false)
	_check(int(shot_res["npc"]) == -1 and d.agents[5].brain.state == S.IDLE, "a dormant agent cannot be shot")
	players[0].aim = 0.0
	players[0].pos = Vector2(30, 280)
	_check(int(d.command(0, NpcBrain.Cmd.WEAPON_DROP)["target"]) == -1, "a dormant agent cannot be commanded")
	var packed := d.pack()
	var mirror: NpcDirector = NpcDirector.new(w["level"], _tuning(), _diff(), players, 5)
	mirror.unpack(packed[0], packed[1], packed[2])
	_check(mirror.agents[5].dormant and mirror.agents[6].dormant and not mirror.agents[0].dormant, "the dormant flag survives packing")
	players[0].pos = Vector2(900, 500)  # nobody near the arrival point: the order alone sends them
	players[1].pos = Vector2(900, 540)
	d.activate_reinforcements(Vector2(110, 500))
	_check(not d.agents[5].dormant and not d.agents[6].dormant and d.agents[5].home == Vector2(110, 500), "arrival wakes both and sets their post")
	d.tick(0.1)
	_check(d.agents[5].brain.state == S.INVESTIGATE, "arrived reinforcements head for the entrance")
	for i in 40:
		d.tick(0.1)
		await physics_frame
	_check(d.agents[5].pos.distance_to(start_pos) > 20.0, "and they actually move (%s)" % str(d.agents[5].pos))
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
