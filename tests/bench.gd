extends Node
## Timing of the per-frame hot paths, headless (CPU only, no drawing):
##   Godot_console.exe --headless --path D:\TOPDOWNRON res://tests/bench.tscn

const SPOTS: Array[Vector2] = [Vector2(150, 480), Vector2(400, 300), Vector2(800, 300), Vector2(1200, 300),
		Vector2(500, 700), Vector2(1100, 700), Vector2(700, 500), Vector2(300, 500)]

var _w: NetWorld


func _ready() -> void:
	Session.host(true)
	_w = NetWorld.new()
	add_child(_w)
	for i in 4:
		await get_tree().physics_frame
	_w.running = true
	_w.mission.mark_ready(0)
	_w.mission.mark_ready(1)
	var lv := _w.level
	var view: WorldView = _w.get_node("View")
	_w.players[0].flash = true
	_w.players[0].laser = true
	_time("level.visibility_polygon (r 700)", 200, func() -> void:
		for p in SPOTS:
			lv.visibility_polygon(p, 700.0), SPOTS.size())
	_time("level.cone_polygon (flashlight)", 200, func() -> void:
		for p in SPOTS:
			lv.cone_polygon(p, 0.3, 45.0, 380.0), SPOTS.size())
	_time("level.blockers_between", 2000, func() -> void:
		for p in SPOTS:
			lv.blockers_between(p, Vector2(1300, 750)), SPOTS.size())
	_time("level.ray_hit", 2000, func() -> void:
		for p in SPOTS:
			lv.ray_hit(p, Vector2(1300, 750)), SPOTS.size())
	_time("level.is_dark", 5000, func() -> void:
		for p in SPOTS:
			lv.is_dark(p), SPOTS.size())
	_time("level.find_path", 300, func() -> void:
		lv.find_path(Vector2(300, 300), Vector2(1250, 700)))
	view._headless = false
	_time("WorldView._physics_process", 300, func() -> void:
		view._physics_process(1.0 / 60.0))
	view._headless = true
	_time("director.tick (calm)", 600, func() -> void:
		_w.director.tick(1.0 / 60.0))
	for a in _w.director.agents:
		if not a.dormant:
			_w.director.on_sound(SoundProp.Kind.GUNSHOT, a.pos + Vector2(30, 0))
	_w.director.tick(1.0 / 60.0)
	_time("director.tick (alerted)", 600, func() -> void:
		_w.director.on_sound(SoundProp.Kind.FOOTSTEP, Vector2(700, 500))
		_w.director.tick(1.0 / 60.0))
	_time("director.pack (snapshot)", 2000, func() -> void:
		_w.director.pack())
	_time("NetWorld._step_host", 600, func() -> void:
		_w._step_host(1.0 / 60.0, Vector2.ZERO))
	_time("SfxSynth: whole stand-in bank", 3, func() -> void:
		[SfxSynth.gunshot(1, true), SfxSynth.gunshot(2, true), SfxSynth.gunshot(3, true),
		SfxSynth.gunshot(4, false), SfxSynth.gunshot(5, false), SfxSynth.gunshot(6, false),
		SfxSynth.footstep(10), SfxSynth.footstep(11), SfxSynth.footstep(12), SfxSynth.footstep(13),
		SfxSynth.door(21, 0.6, 0.6), SfxSynth.door(22, 0.7, 0.6), SfxSynth.door(31, 0.35, 0.4),
		SfxSynth.kick(41), SfxSynth.kick(42), SfxSynth.shout(51, 100.0, 0.7, 0.5), SfxSynth.shout(52, 125.0, 0.6, 0.5),
		SfxSynth.shout(53, 150.0, 0.65, 0.5), SfxSynth.shout(61, 380.0, 0.9, 2.0), SfxSynth.shout(62, 450.0, 1.0, 2.0),
		SfxSynth.taser(71), SfxSynth.siren(), SfxSynth.reload_sound(81), SfxSynth.reload_sound(82), SfxSynth.hit(91),
		SfxSynth.hit(92), SfxSynth.hurt(95), SfxSynth.radio(97), SfxSynth.radio(98), SfxSynth.heart(), SfxSynth.hum(), SfxSynth.ringing()])
	Session.leave()
	get_tree().quit()


func _time(label: String, n: int, f: Callable, per: int = 1) -> void:
	var t0 := Time.get_ticks_usec()
	for i in n:
		f.call()
	var us := float(Time.get_ticks_usec() - t0) / float(n * per)
	print("BENCH %-36s %10.1f us" % [label, us])
