class_name GameAudio
extends Node
## Plays the game's sounds for NetWorld events, heard from the local officer. Every sound is a
## synthesized stand-in (SfxSynth) until a file replaces it: assets/audio/<key>_<n>.wav (several
## numbered variants per key), recorded voice lines assets/audio/voice_<command>_<line>_<take>.wav.
## Loudness uses the same SoundProp rules as the NPC hearing (distance, walls, closed and ajar
## doors); duller buses for far or walled-off sounds, room reverb from where the listener stands,
## ear ringing after a loud bang next to you. F6 mutes, F7 opens the sound audition panel.
## Presentation only: it reads world state and signals.

const BUS_SFX := "Sfx"  ## clear sounds; also holds the ear low-pass and the room reverb
const BUS_MID := "SfxMid"  ## farther sounds, slightly dull
const BUS_FAR := "SfxFar"  ## far sounds, dull
const BUS_MUFFLED := "SfxMuffled"  ## behind a wall or closed door
const FX_EAR := 0  ## effect slots on the Sfx bus
const FX_REVERB := 1
const SAMPLE_DIR := "res://assets/audio/"
const MAX_VARIANTS := 16  ## files <key>_0.wav .. <key>_15.wav
const MAX_TAKES := 4  ## voice_<command>_<line>_0.wav .. _3.wav (different voices or takes)
## Keys a file can replace; <key>_far is an optional set used for faint, distant sounds.
const SAMPLE_KEYS: Array[String] = ["rifle", "rifle_far", "pistol", "pistol_far", "footstep", "door",
		"door_ajar", "kick", "taser", "reload", "hit", "hurt", "siren", "scream", "radio", "heart", "hum"]
const SCREAM_LINE := "꺄악!"

static var _cache: Dictionary = {}  ## synthesized / loaded once per process
static var _voice_cache: Dictionary = {}  ## spoken text -> recorded takes
static var _voice_built := false

var world: NetWorld
var audition_reverb: Dictionary = {}  ## set by the audition panel; overrides the room reverb
var use_far_sets := true  ## false: faint sounds are only treated by the distance buses (F in the audition panel)

var _cfg: Dictionary = {}
var _bank: Dictionary = {}
var _enabled := DisplayServer.get_name() != "headless"
var _listener: AudioListener2D
var _rng := RandomNumberGenerator.new()
var _reloading: Array[bool] = [false, false]
var _ear := 0.0  ## 0..1: how deafened the local officer is right now
var _ear_gap := 0.0
var _ring_player: AudioStreamPlayer
var _reverb_now := {"room_size": 0.1, "wet": 0.04, "damping": 0.7}
var _last_pick: Dictionary = {}
var _voice_quiet := 0.0  ## a recorded line just played: skip the synthesized shout that follows
var _heart_t := 0.0
var _last_reinforce := 0


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/audio.json")
	use_far_sets = bool(_cfg["dull"]["use_far_sets"])
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
	_ring_player = AudioStreamPlayer.new()
	_ring_player.stream = _bank["ring"][0]
	_ring_player.bus = "Master"  # the ringing is inside your head: not dulled by the Sfx bus
	add_child(_ring_player)
	_last_reinforce = world.mission.reinforce
	world.sound_emitted.connect(_on_sound)
	world.shot_fired.connect(_on_shot)
	world.damaged.connect(_on_damaged)
	world.speech_emitted.connect(_on_speech)
	var panel := AudioAudition.new()
	panel.audio = self
	add_child(panel)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F6:
		AudioServer.set_bus_mute(0, not AudioServer.is_bus_mute(0))
		world.notice_emitted.emit(tr("소리 끔") if AudioServer.is_bus_mute(0) else tr("소리 켬"))


func _process(delta: float) -> void:
	var me := world.display_pos(world.my_slot)
	_listener.position = me
	if not _enabled:
		return
	_voice_quiet = maxf(_voice_quiet - delta, 0.0)
	_update_room_and_ears(me, delta)
	var extra: Dictionary = _cfg["extra"]["reload"]
	for s in 2:
		var ps := world.players[s]
		if not ps.present or ps.weapons.size() <= ps.active:
			continue
		var r := ps.weapons[ps.active].reloading
		if r and not _reloading[s]:
			_play("reload", world.display_pos(s), float(extra["radius"]), float(extra["db"]))
		_reloading[s] = r
	_update_alerts(delta)


## Radio squelch when the reinforcement warning goes out, heartbeat while badly hurt.
func _update_alerts(delta: float) -> void:
	var rs: int = world.mission.reinforce
	if rs == ReinforcementClock.Phase.WARNED and _last_reinforce != rs:
		_play_ui("radio", float(_cfg["extra"]["radio_db"]))
	_last_reinforce = rs
	var me := world.players[world.my_slot]
	_heart_t -= delta
	if me.present and me.hp > 0 and me.hp * 5 <= me.max_hp * 2 and _heart_t <= 0.0:  # 40 % health or less
		_play_ui("heart", float(_cfg["extra"]["heart_db"]))
		_heart_t = lerpf(0.65, 1.1, float(me.hp) / maxf(me.max_hp * 0.4, 1.0))


# ---- setup --------------------------------------------------------------------

## Sfx bus (ear low-pass, then room reverb) plus three dulling buses (low-pass, feed Sfx);
## created once per process.
func _setup_buses() -> void:
	if AudioServer.get_bus_index(BUS_SFX) >= 0:
		return
	AudioServer.add_bus()
	var sfx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(sfx, BUS_SFX)
	AudioServer.set_bus_volume_db(sfx, float(_cfg["sfx_db"]))
	var ear := AudioEffectLowPassFilter.new()
	ear.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(sfx, ear)  # slot FX_EAR
	AudioServer.add_bus_effect(sfx, AudioEffectReverb.new())  # slot FX_REVERB, eased per room
	var dull: Dictionary = _cfg["dull"]
	for entry in [[BUS_MID, float(dull["mid_hz"]), "mid"], [BUS_FAR, float(dull["far_hz"]), "far"], [BUS_MUFFLED, float(_cfg["muffle_hz"]), ""]]:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, entry[0])
		AudioServer.set_bus_send(idx, BUS_SFX)
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = entry[1]
		AudioServer.add_bus_effect(idx, lp)
		if entry[2] != "":  # distance: duller, then the low thump stays and the echo tail grows
			var shelf := AudioEffectLowShelfFilter.new()
			shelf.cutoff_hz = 150.0
			shelf.gain = db_to_linear(float(dull[entry[2] + "_boom_db"]))
			AudioServer.add_bus_effect(idx, shelf)
			var rv: Dictionary = dull[entry[2] + "_reverb"]
			var echo := AudioEffectReverb.new()
			echo.room_size = float(rv["room_size"])
			echo.wet = float(rv["wet"])
			echo.damping = float(rv["damping"])
			AudioServer.add_bus_effect(idx, echo)
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
			"radio": [SfxSynth.radio(97), SfxSynth.radio(98)],
			"heart": [SfxSynth.heart()],
			"hum": [SfxSynth.hum()],
			"ring": [SfxSynth.ringing()],
		}
		print("[audio] synthesized in %d ms" % (Time.get_ticks_msec() - t0))
		for key in SAMPLE_KEYS:  # files replace the stand-in of the same name; no file keeps it
			var files := sample_streams(key)
			if not files.is_empty():
				if key == "hum":  # room tone loops over its whole length
					for f in files:
						loop_whole(f)
				_cache[key] = files
				print("[audio] %s: using %d file(s)" % [key, files.size()])
	if not _voice_built:
		_voice_cache = voice_lines(JsonData.load_dict("res://data/commands.json"))
		_voice_built = true
		if not _voice_cache.is_empty():
			print("[audio] recorded voice lines for %d sentence(s)" % _voice_cache.size())
	_bank = _cache


## Numbered files <key>_<n>.wav that exist, loaded (empty when none: assets/audio is not committed).
static func sample_streams(key: String, dir := SAMPLE_DIR) -> Array:
	var out: Array = []
	for n in MAX_VARIANTS:
		var path := "%s%s_%d.wav" % [dir, key, n]
		if ResourceLoader.exists(path):
			out.append(load(path))
	return out


## Spoken text -> recorded takes, for every command sentence (commands.json order) and the NPC
## scream that has a file voice_<command>_<line>_<take>.wav / voice_npc_scream_<take>.wav.
static func voice_lines(lines: Dictionary, dir := SAMPLE_DIR) -> Dictionary:
	var out := {}
	var stems := voice_stems(lines)
	for text in stems:
		var takes := _takes(stems[text], dir)
		if not takes.is_empty():
			out[text] = takes
	return out


## Spoken text -> file name stem: voice_<command>_<line index> for every commands.json sentence,
## voice_npc_scream for the NPC scream. The recording sheet (tools/audio) uses the same names.
static func voice_stems(lines: Dictionary) -> Dictionary:
	var out := {}
	for key in NpcBrain.CMD_KEYS:
		var options: Array = lines.get(key, [])
		for i in options.size():
			out[str(options[i])] = "voice_%s_%d" % [key, i]
	out[SCREAM_LINE] = "voice_npc_scream"
	return out


## Makes a loaded WAV repeat over its whole length (room tone files are prepared to loop seamlessly).
static func loop_whole(stream: AudioStream) -> void:
	var wav := stream as AudioStreamWAV
	if wav != null:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * wav.mix_rate)


static func _takes(stem: String, dir: String) -> Array:
	var out: Array = []
	for t in MAX_TAKES:
		var path := "%s%s_%d.wav" % [dir, stem, t]
		if ResourceLoader.exists(path):
			out.append(load(path))
	return out


# ---- hearing ------------------------------------------------------------------

## How a sound at `pos` arrives at `at`: loudness 0..1 (SoundProp rules) and whether a wall
## or closed door is in the way (muffled).
func hearing(pos: Vector2, at: Vector2, radius: float) -> Dictionary:
	var blockers := world.level.blockers_between(at, pos)
	return {
		"loud": SoundProp.loudness(at.distance_to(pos), blockers, world.tuning["sound_penalty"], radius, 1.0),
		"muffled": int(blockers["walls"]) + int(blockers["closed"]) > 0}


## Which bus a sound goes through: muffled behind solids, duller the farther it is.
func bus_for(loud: float, muffled: bool) -> String:
	var dull: Dictionary = _cfg["dull"]
	if muffled:
		return BUS_MUFFLED
	if loud < float(dull["far_below"]):
		return BUS_FAR
	if loud < float(dull["mid_below"]):
		return BUS_MID
	return BUS_SFX


## The variant set for a faint sound: <key>_far when it exists, else the normal set.
func set_key(key: String, loud: float) -> String:
	var far := key + "_far"
	return far if use_far_sets and loud < float(_cfg["dull"]["far_below"]) and _bank.has(far) else key


## A random variant that is not the one played last for this key.
func _pick(key: String, variants: Array) -> AudioStream:
	var i := _rng.randi() % variants.size()
	if variants.size() > 1 and i == int(_last_pick.get(key, -1)):
		i = (i + 1 + _rng.randi() % (variants.size() - 1)) % variants.size()
	_last_pick[key] = i
	return variants[i]


## Reverb for the space the listener stands in: bigger rooms ring longer, outside is nearly dry.
func reverb_for(at: Vector2) -> Dictionary:
	var lv := world.level
	var i := lv.room_at(at)
	if i < 0 and not lv.building.has_point(at):
		return reverb_outdoor()
	var longest_m := 8.0  # doorways between rooms: a middling room
	if i >= 0:
		var r: Rect2 = lv.rooms[i]["rect"]
		longest_m = maxf(r.size.x, r.size.y) / float(_cfg["px_per_m"])
	return reverb_for_size(longest_m)


func reverb_outdoor() -> Dictionary:
	var o: Dictionary = _cfg["reverb"]["outdoor"]
	return {"room_size": o["room_size"], "wet": o["wet"], "damping": o["damping"]}


func reverb_for_size(longest_m: float) -> Dictionary:
	var ind: Dictionary = _cfg["reverb"]["indoor"]
	return {"room_size": clampf(longest_m * float(ind["size_per_m"]), float(ind["min"]), float(ind["max"])),
			"wet": ind["wet"], "damping": ind["damping"]}


## Loud bang near the listener: the ears ring, the world dulls and ducks for a few seconds.
func _deafen(loud: float) -> void:
	var e: Dictionary = _cfg["ear"]
	if loud < float(e["trigger_loud"]) or _ear_gap > 0.0:
		return
	_ear = remap(loud, float(e["trigger_loud"]), 1.0, 0.6, 1.0)
	_ear_gap = float(e["min_gap_s"])
	if _ring_player != null:
		_ring_player.play()


func _update_room_and_ears(me: Vector2, delta: float) -> void:
	var sfx := AudioServer.get_bus_index(BUS_SFX)
	var target := audition_reverb if not audition_reverb.is_empty() else reverb_for(me)
	var k := minf(delta * float(_cfg["reverb"]["ease_per_s"]), 1.0)
	for key in _reverb_now:
		_reverb_now[key] = lerpf(_reverb_now[key], float(target[key]), k)
	var rv := AudioServer.get_bus_effect(sfx, FX_REVERB) as AudioEffectReverb
	rv.room_size = _reverb_now["room_size"]
	rv.wet = _reverb_now["wet"]
	rv.damping = _reverb_now["damping"]
	rv.dry = 1.0
	var e: Dictionary = _cfg["ear"]
	_ear = maxf(_ear - delta / float(e["duration_s"]), 0.0)
	_ear_gap = maxf(_ear_gap - delta, 0.0)
	var s := _ear * _ear * (3.0 - 2.0 * _ear)  # smoothstep: sharp onset, slow recovery
	(AudioServer.get_bus_effect(sfx, FX_EAR) as AudioEffectLowPassFilter).cutoff_hz = exp(lerpf(log(20000.0), log(float(e["cutoff_hz"])), s))
	AudioServer.set_bus_volume_db(sfx, float(_cfg["sfx_db"]) + float(e["duck_db"]) * s)
	if _ring_player != null:
		_ring_player.volume_db = float(e["ring_db"]) + linear_to_db(maxf(_ear, 0.0001))


# ---- playback -----------------------------------------------------------------

## Positional sound at `pos`. `takes` (recorded lines) override the bank set of `key`.
func _play(key: String, pos: Vector2, radius: float, base_db: float, takes: Array = []) -> void:
	var h := hearing(pos, world.display_pos(world.my_slot), radius)
	if float(h["loud"]) < float(_cfg["min_loudness"]):
		return
	var used := key if not takes.is_empty() else set_key(key, float(h["loud"]))
	var variants: Array = takes if not takes.is_empty() else _bank.get(used, [])
	if variants.is_empty():
		return
	var p := AudioStreamPlayer2D.new()
	p.stream = _pick(used, variants)
	p.position = pos
	p.max_distance = 100000.0  # distance falloff comes from SoundProp, not the engine
	p.volume_db = base_db + linear_to_db(pow(float(h["loud"]), 1.3))
	p.pitch_scale = _rng.randf_range(0.94, 1.06)
	p.bus = bus_for(float(h["loud"]), h["muffled"])
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()


## Sound inside your own head or radio: not positional.
func _play_ui(key: String, db: float) -> void:
	var variants: Array = _bank.get(key, [])
	if variants.is_empty():
		return
	var p := AudioStreamPlayer.new()
	p.stream = _pick(key, variants)
	p.bus = BUS_SFX
	p.volume_db = db
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()


func _rifle_at(pos: Vector2) -> bool:
	for ps in world.players:
		if ps.present and ps.pos.distance_to(pos) < 40.0 and ps.weapon_kinds.size() > ps.active:
			return ps.weapon_kinds[ps.active].begins_with("rifle")
	return false  # NPC shooters carry pistols


# ---- audition panel API ---------------------------------------------------------

func bank_keys() -> Array:
	var keys := _bank.keys()
	keys.sort()
	return keys


func variants_of(key: String) -> Array:
	return _bank.get(key, [])


## Base volume (dB) of a bank key: the matching kind in audio.json, else 0.
func base_db_for(key: String) -> float:
	var nm := key.trim_suffix("_far")
	if nm == "rifle" or nm == "pistol":
		nm = "gunshot"
	return float(_cfg["kind_db"].get(nm, 0.0))


## Plays variant `variant` of `key` as it would sound at loudness `loud` (muffled behind a wall).
func audition_play(key: String, variant: int, loud: float, muffled: bool) -> void:
	var used := set_key(key, loud)
	var variants: Array = _bank.get(used, [])
	if variants.is_empty():
		return
	var p := AudioStreamPlayer.new()
	p.stream = variants[variant % variants.size()]
	p.bus = bus_for(loud, muffled)
	p.volume_db = base_db_for(key) + linear_to_db(pow(loud, 1.3))
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()


# ---- events -------------------------------------------------------------------

func _on_sound(kind: int, pos: Vector2) -> void:
	if (kind == SoundProp.Kind.VOICE or kind == SoundProp.Kind.SCREAM) and _voice_quiet > 0.0:
		return  # a recorded line just covered this one
	var nm: String = SoundProp.NAMES[kind]
	var db := float(_cfg["kind_db"][nm])
	var key := nm
	if kind == SoundProp.Kind.GUNSHOT:
		key = "rifle" if _rifle_at(pos) else "pistol"
		var me := world.display_pos(world.my_slot)
		if pos.distance_to(me) > 30.0:  # someone else's shot right next to you; your own do not deafen
			_deafen(float(hearing(pos, me, float(world.tuning["sound_radius"][nm]))["loud"]))
	elif kind == SoundProp.Kind.FOOTSTEP and pos.distance_to(world.display_pos(world.my_slot)) < 24.0:
		db += float(_cfg["own_footstep_db"])  # your own steps sit under the room
	_play(key, pos, float(world.tuning["sound_radius"][nm]), db)


## A recorded line for this exact sentence replaces the synthesized shout that follows it.
func _on_speech(text: String, pos: Vector2, _from_npc: bool) -> void:
	var takes: Array = _voice_cache.get(text, [])
	if takes.is_empty():
		return
	_voice_quiet = 0.5
	var radius_key := "scream" if text == SCREAM_LINE else "voice"
	_play("voice:" + text, pos, float(world.tuning["sound_radius"][radius_key]), float(_cfg["extra"]["voice_db"]), takes)


func _on_shot(_shooter: int, _from: Vector2, to: Vector2, hit_npc: bool) -> void:
	if hit_npc:
		var h: Dictionary = _cfg["extra"]["hit"]
		_play("hit", to, float(h["radius"]), float(h["db"]))


func _on_damaged(slot: int) -> void:
	if slot == world.my_slot:
		_play_ui("hurt", float(_cfg["extra"]["hurt_db"]))
