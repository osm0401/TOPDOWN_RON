class_name GameAudio
extends Node
## Plays the synthesized placeholder sounds (SfxSynth) for NetWorld events, heard from the
## local officer. Loudness uses the same SoundProp rules as the NPC hearing (distance,
## walls, closed and ajar doors); sounds behind something solid go through a low-pass bus.
## F6 mutes. Presentation only: it reads world state and signals.

const BUS_SFX := "Sfx"
const BUS_MUFFLED := "SfxMuffled"

static var _cache: Dictionary = {}  ## synthesized once per process

var world: NetWorld

var _cfg: Dictionary = {}
var _bank: Dictionary = {}
var _enabled := DisplayServer.get_name() != "headless"
var _listener: AudioListener2D
var _rng := RandomNumberGenerator.new()
var _reloading: Array[bool] = [false, false]


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/audio.json")
	_setup_buses()
	_listener = AudioListener2D.new()
	add_child(_listener)
	_listener.make_current()
	if not _enabled:
		return
	_build_bank()
	var amb := AudioStreamPlayer.new()
	amb.stream = _bank["hum"][0]
	amb.bus = BUS_SFX
	amb.volume_db = float(_cfg["ambient_db"])
	add_child(amb)
	amb.play()
	world.sound_emitted.connect(_on_sound)
	world.shot_fired.connect(_on_shot)
	world.damaged.connect(_on_damaged)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F6:
		AudioServer.set_bus_mute(0, not AudioServer.is_bus_mute(0))
		world.notice_emitted.emit(tr("소리 끔") if AudioServer.is_bus_mute(0) else tr("소리 켬"))


func _process(_delta: float) -> void:
	var me := world.display_pos(world.my_slot)
	_listener.position = me
	if not _enabled:
		return
	var extra: Dictionary = _cfg["extra"]["reload"]
	for s in 2:
		var ps := world.players[s]
		if not ps.present or ps.weapons.size() <= ps.active:
			continue
		var r := ps.weapons[ps.active].reloading
		if r and not _reloading[s]:
			_play("reload", world.display_pos(s), float(extra["radius"]), float(extra["db"]))
		_reloading[s] = r


# ---- setup --------------------------------------------------------------------

## Sfx bus (reverb) and SfxMuffled bus (low-pass, feeds Sfx); created once per process.
func _setup_buses() -> void:
	if AudioServer.get_bus_index(BUS_SFX) >= 0:
		return
	AudioServer.add_bus()
	var sfx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(sfx, BUS_SFX)
	AudioServer.set_bus_volume_db(sfx, float(_cfg["sfx_db"]))
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.35
	reverb.wet = 0.12
	AudioServer.add_bus_effect(sfx, reverb)
	AudioServer.add_bus()
	var muffled := AudioServer.bus_count - 1
	AudioServer.set_bus_name(muffled, BUS_MUFFLED)
	AudioServer.set_bus_send(muffled, BUS_SFX)
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = float(_cfg["muffle_hz"])
	AudioServer.add_bus_effect(muffled, lp)
	if AudioServer.get_bus_effect_count(0) == 0:
		AudioServer.add_bus_effect(0, AudioEffectLimiter.new())


func _build_bank() -> void:
	if _cache.is_empty():
		var t0 := Time.get_ticks_msec()
		_cache = {
			"rifle": [SfxSynth.gunshot(1, true), SfxSynth.gunshot(2, true), SfxSynth.gunshot(3, true)],
			"pistol": [SfxSynth.gunshot(4, false), SfxSynth.gunshot(5, false), SfxSynth.gunshot(6, false)],
			"footstep": [SfxSynth.footstep(10), SfxSynth.footstep(11), SfxSynth.footstep(12), SfxSynth.footstep(13)],
			"door": [SfxSynth.door(21, 0.6, 0.6), SfxSynth.door(22, 0.7, 0.6)],
			"door_ajar": [SfxSynth.door(31, 0.35, 0.4)],
			"kick": [SfxSynth.kick(41), SfxSynth.kick(42)],
			"voice": [SfxSynth.shout(51, 100.0, 0.7, 0.5), SfxSynth.shout(52, 125.0, 0.6, 0.5), SfxSynth.shout(53, 150.0, 0.65, 0.5)],
			"scream": [SfxSynth.shout(61, 380.0, 0.9, 2.0), SfxSynth.shout(62, 450.0, 1.0, 2.0)],
			"taser": [SfxSynth.taser(71)],
			"siren": [SfxSynth.siren()],
			"reload": [SfxSynth.reload_sound(81), SfxSynth.reload_sound(82)],
			"hit": [SfxSynth.hit(91), SfxSynth.hit(92)],
			"hurt": [SfxSynth.hurt(95)],
			"hum": [SfxSynth.hum()],
		}
		print("[audio] synthesized in %d ms" % (Time.get_ticks_msec() - t0))
	_bank = _cache


# ---- hearing ------------------------------------------------------------------

## How a sound at `pos` arrives at `at`: loudness 0..1 (SoundProp rules) and whether a wall
## or closed door is in the way (muffled).
func hearing(pos: Vector2, at: Vector2, radius: float) -> Dictionary:
	var blockers := world.level.blockers_between(at, pos)
	return {
		"loud": SoundProp.loudness(at.distance_to(pos), blockers, world.tuning["sound_penalty"], radius, 1.0),
		"muffled": int(blockers["walls"]) + int(blockers["closed"]) > 0}


func _play(key: String, pos: Vector2, radius: float, base_db: float) -> void:
	var h := hearing(pos, world.display_pos(world.my_slot), radius)
	var variants: Array = _bank.get(key, [])
	if float(h["loud"]) < float(_cfg["min_loudness"]) or variants.is_empty():
		return
	var p := AudioStreamPlayer2D.new()
	p.stream = variants[_rng.randi() % variants.size()]
	p.position = pos
	p.max_distance = 100000.0  # distance falloff comes from SoundProp, not the engine
	p.volume_db = base_db + linear_to_db(pow(float(h["loud"]), 1.3))
	p.pitch_scale = _rng.randf_range(0.94, 1.06)
	p.bus = BUS_MUFFLED if h["muffled"] else BUS_SFX
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()


func _rifle_at(pos: Vector2) -> bool:
	for ps in world.players:
		if ps.present and ps.pos.distance_to(pos) < 40.0 and ps.weapon_kinds.size() > ps.active:
			return ps.weapon_kinds[ps.active].begins_with("rifle")
	return false  # NPC shooters carry pistols


# ---- events -------------------------------------------------------------------

func _on_sound(kind: int, pos: Vector2) -> void:
	var nm: String = SoundProp.NAMES[kind]
	var db := float(_cfg["kind_db"][nm])
	var key := nm
	if kind == SoundProp.Kind.GUNSHOT:
		key = "rifle" if _rifle_at(pos) else "pistol"
	elif kind == SoundProp.Kind.FOOTSTEP and pos.distance_to(world.display_pos(world.my_slot)) < 24.0:
		db += float(_cfg["own_footstep_db"])  # your own steps sit under the room
	_play(key, pos, float(world.tuning["sound_radius"][nm]), db)


func _on_shot(_shooter: int, _from: Vector2, to: Vector2, hit_npc: bool) -> void:
	if hit_npc:
		var h: Dictionary = _cfg["extra"]["hit"]
		_play("hit", to, float(h["radius"]), float(h["db"]))


func _on_damaged(slot: int) -> void:
	if slot != world.my_slot:
		return
	var p := AudioStreamPlayer.new()  # your own pain: not positional
	p.stream = _bank["hurt"][0]
	p.bus = BUS_SFX
	p.volume_db = float(_cfg["extra"]["hurt_db"])
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()
