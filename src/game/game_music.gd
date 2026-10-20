class_name GameMusic
extends Node
## Tension music: the MusicSynth loops (or assets/audio/music_<layer>_0.wav) play together on
## the Music bus and each fades in with the TensionMeter level (data/audio.json "music").
## Briefing: the low drone alone, quietly. Result screen: everything fades out.
## Volume: the "music" setting times the configured level.

const BUS := "Music"

var world: NetWorld
var meter := TensionMeter.new()

var _cfg: Dictionary = {}
var _players: Dictionary = {}  ## layer -> AudioStreamPlayer, once every layer is ready
var _amp: Dictionary = {}  ## layer -> eased 0..1 volume
var _streams: Dictionary = {}  ## layer -> stream from a file
var _last_reinforce := 0


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/audio.json")["music"]
	meter.configure(_cfg)
	if AudioServer.get_bus_index(BUS) < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, BUS)  # sends to Master: the ear ringing and room echo leave it alone
	for layer in MusicSynth.LAYERS:
		var files := GameAudio.sample_streams("music_" + layer)
		if not files.is_empty():
			GameAudio.loop_whole(files[0])
			_streams[layer] = files[0]
	if DisplayServer.get_name() != "headless":
		MusicSynth.prepare(_streams.keys())  # normally already started in the lobby
	_last_reinforce = world.mission.reinforce
	world.shot_fired.connect(_on_shot)
	world.damaged.connect(_on_damaged)


func _process(delta: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS),
			float(_cfg["db"]) + GameSettings.volume_db(float(GameSettings.value("audio", "music"))))
	var rs: int = world.mission.reinforce
	if rs == ReinforcementClock.Phase.WARNED and rs != _last_reinforce:
		meter.bump(float(_cfg["events"]["reinforce_warned"]))
	_last_reinforce = rs
	meter.update(delta, situation_floor())
	if _players.is_empty() and not _start():
		return
	var phase := world.mission.phase
	var layers: Dictionary = _cfg["layers"]
	for layer: String in _players:
		var lc: Dictionary = layers[layer]
		var want := 0.0
		if phase == MissionState.Phase.ACTIVE:
			want = TensionMeter.layer_gain(meter.level, float(lc["from"]), float(lc["full"]))
		elif phase == MissionState.Phase.BRIEFING and layer == "drone":
			want = db_to_linear(float(_cfg["briefing_db"]))
		_amp[layer] = move_toward(float(_amp.get(layer, 0.0)), want, delta * (1.5 if want > float(_amp.get(layer, 0.0)) else 0.5))
		(_players[layer] as AudioStreamPlayer).volume_db = float(lc["db"]) + GameSettings.volume_db(float(_amp[layer]))


## Starts every layer together (they share one length and tempo) once all are ready.
func _start() -> bool:
	var made := MusicSynth.ready_layers()
	for layer in MusicSynth.LAYERS:
		if not _streams.has(layer) and not made.has(layer):
			return false
	for layer in MusicSynth.LAYERS:
		var p := AudioStreamPlayer.new()
		p.stream = _streams.get(layer, made.get(layer))
		p.bus = BUS
		p.volume_db = -80.0
		add_child(p)
		_players[layer] = p
	for layer in MusicSynth.LAYERS:
		(_players[layer] as AudioStreamPlayer).play()
	return true


## The lowest the tension may sink to right now: enemies near you that are searching, have
## seen an officer, or are fighting.
func situation_floor() -> float:
	if world.mission.phase != MissionState.Phase.ACTIVE:
		return 0.0
	var fc: Dictionary = _cfg["floor"]
	var me := world.display_pos(world.my_slot)
	var reach := float(fc["reach_px"])
	var S := NpcBrain.State
	var out := 0.0
	for a in world.director.agents:
		if a.dormant or a.brain.role != NpcBrain.Role.ENEMY or a.pos.distance_to(me) > reach:
			continue
		match a.brain.state:
			S.INVESTIGATE:
				out = maxf(out, float(fc["investigate"]))
			S.SPOTTED, S.THREAT:
				out = maxf(out, float(fc["spotted"]))
			S.ATTACK:
				out = maxf(out, float(fc["attack"]))
	return out


func _on_shot(shooter: int, from: Vector2, _to: Vector2, _hit_npc: bool) -> void:
	var ev: Dictionary = _cfg["events"]
	var near := from.distance_to(world.display_pos(world.my_slot)) <= float(_cfg["near_px"])
	if shooter >= 2:
		meter.bump(float(ev["enemy_shot_near"] if near else ev["enemy_shot_far"]))
	else:
		meter.bump(float(ev["our_shot_near"] if near else ev["our_shot_far"]))


func _on_damaged(slot: int) -> void:
	if slot == world.my_slot:
		meter.bump(float(_cfg["events"]["hurt"]))
