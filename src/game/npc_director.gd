class_name NpcDirector
extends RefCounted
## Host-side NPC simulation: perception (sound / sight / laser), movement along A* paths
## (opening doors on the way), shooting, commands, restraint and network packing.
## The decisions themselves live in NpcBrain (pure). A client builds one too, but only
## calls unpack() on it, never tick().

signal sound_emitted(kind: int, pos: Vector2)
signal shot(npc: int, from: Vector2, to: Vector2)
signal player_hit(slot: int, npc: int)
signal speech(text: String, pos: Vector2)
signal doors_changed
signal npc_killed(npc: int, slot: int)

const ARRIVE_DIST := 16.0
const DOOR_TOUCH := 18.0
const MOVING_STATES: Array[int] = [NpcBrain.State.IDLE, NpcBrain.State.INVESTIGATE, NpcBrain.State.FLEE]


class Agent extends RefCounted:
	var brain: NpcBrain
	var pos := Vector2.ZERO
	var home := Vector2.ZERO
	var path := PackedVector2Array()
	var path_i := 0
	var path_goal := Vector2.INF
	var target_slot := -1
	var suspect := false          ## the designated suspect (must be taken alive)
	var dormant := false          ## reinforcement not arrived yet: not simulated, seen, heard or shot
	var clues: Array[String] = []  ## visible identifying marks: "cap", "band"


var level: Level
var agents: Array[Agent] = []
var players: Array[PlayerState]

var _t: Dictionary
var _np: Dictionary
var _diff: Dictionary
var _params: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _queue: Array[Dictionary] = []
var _pl_prev: Array[Vector2] = []
var _pl_speed: Array[float] = []  ## px/s of each officer (smoothed): a moving officer is harder to hit


func _init(lv: Level, tuning: Dictionary, diff: Dictionary, player_list: Array[PlayerState], seed_value: int) -> void:
	level = lv
	_t = tuning
	_np = tuning["npc"]
	_diff = diff
	players = player_list
	_rng.seed = seed_value
	_params.merge(_np)
	_params.merge(diff, true)
	var cmd: Dictionary = tuning["commands"]
	_params["chance"] = cmd["chance"]
	for k in ["suppressed_bonus", "hurt_bonus", "outnumbered_bonus", "engaged_mult", "civilian_chance"]:
		_params[k] = cmd[k]
	for def in lv.npc_defs:
		var a := Agent.new()
		var role: int = NpcBrain.Role.ENEMY if def["role"] == "enemy" else NpcBrain.Role.CIVILIAN
		a.brain = NpcBrain.new(role, _params, _rng, bool(def["feigns"]))
		a.pos = def["pos"]
		a.home = a.pos
		a.brain.pos = a.pos
		a.brain.facing = float(def["facing"])
		a.suspect = bool(def["suspect"])
		a.dormant = bool(def["reinforcement"])
		a.clues.assign(def["clues"])
		agents.append(a)


## A sound the NPCs may hear (source = agent index that made it, -1 for players).
func on_sound(kind: int, at: Vector2, source: int = -1) -> void:
	_queue.append({"kind": kind, "pos": at, "src": source})


func tick(delta: float) -> void:
	_track_players(delta)
	var sounds := _queue
	_queue = []
	var alerts: Array[Dictionary] = []
	for i in agents.size():
		_tick_agent(i, delta, sounds, alerts)
	for al in alerts:
		_share_alert(int(al["from"]), al["pos"])


func _track_players(delta: float) -> void:
	if _pl_prev.size() != players.size():
		_pl_prev.clear()
		_pl_speed.clear()
		for pl in players:
			_pl_prev.append(pl.pos)
			_pl_speed.append(0.0)
	for s in players.size():
		var moved := _pl_prev[s].distance_to(players[s].pos)
		var v := moved / delta if delta > 0.0 and moved < 100.0 else 0.0  # a jump of 100 px is a teleport
		_pl_speed[s] = lerpf(_pl_speed[s], v, minf(delta * 8.0, 1.0))
		_pl_prev[s] = players[s].pos


## How much harder officer `slot` is to hit while moving: 1 standing still .. aim_move_mult at full speed.
func moving_target_mult(slot: int) -> float:
	if slot < 0 or slot >= _pl_speed.size():
		return 1.0
	var k := clampf(_pl_speed[slot] / maxf(float(_t["move_speed"]), 1.0), 0.0, 1.0)
	return lerpf(1.0, float(_np.get("aim_move_mult", 1.0)), k)


# ---- player actions on NPCs --------------------------------------------------

## Resolves a bullet fired along from->to. Low cover just in front of the NPC it would hit may
## catch it (cover_mult: {"hard", "soft"} scales the cover's chance, from the round used).
## Returns {"end": Vector2, "npc": int, "cover": prop index that stopped it or -1}.
func resolve_player_shot(slot: int, from: Vector2, to: Vector2, damage: int, stun: bool, cover_mult: Dictionary = {}) -> Dictionary:
	var hit := _nearest_on_segment(from, to)
	var end := to
	var stopped := -1
	if hit >= 0:
		end = Geometry2D.get_closest_point_to_segment(agents[hit].pos, from, to)
		var c := _cover_catch(from, end, agents[hit].brain.state in [NpcBrain.State.HIDE, NpcBrain.State.DOWN] or agents[hit].brain.in_cover, cover_mult)
		if not c.is_empty():
			stopped = int(c["i"])
			end = c["enter"]
			hit = -1
	if hit >= 0:
		var was_alive: bool = agents[hit].brain.alive()
		agents[hit].brain.on_hit(damage, stun, players[slot].pos)
		if was_alive and not agents[hit].brain.alive():
			npc_killed.emit(hit, slot)
	var radius := float(_np["threat_shot_radius"])
	for i in agents.size():
		var a: Agent = agents[i]
		if i == hit or a.dormant or not a.brain.alive():
			continue
		var closest := Geometry2D.get_closest_point_to_segment(a.pos, from, end)
		if closest.distance_to(a.pos) <= radius and level.has_los(from, a.pos):
			a.brain.on_threat_shot()
	return {"end": end, "npc": hit, "cover": stopped}


## The low cover that catches a bullet flying from `from` to someone at `at`, or {}: a piece the
## line crosses within reach_px before `at` stops it with its chance (hard / soft, times
## crouch_mult when the target is crouched or lying behind it, times the round's cover_mult).
func _cover_catch(from: Vector2, at: Vector2, low: bool, cover_mult: Dictionary) -> Dictionary:
	var cc: Dictionary = _t["cover"]
	for c in level.cover_between(from, at):
		if (c["exit"] as Vector2).distance_to(at) > float(cc["reach_px"]):
			continue
		var kind: String = c["cover"]
		var chance := float(cc["block"][kind]) * float(cover_mult.get(kind, 1.0)) * (float(cc["crouch_mult"]) if low else 1.0)
		if _rng.randf() < minf(chance, 0.95):
			return c
	return {}


## Taser dart: stuns the nearest NPC on the line. Returns its index or -1.
func taser(slot: int, max_range: float) -> int:
	var pl: PlayerState = players[slot]
	var to := pl.pos + Vector2.from_angle(pl.aim) * max_range
	var wall := level.ray_hit(pl.pos, to)
	if not wall.is_empty():
		to = wall["position"]
	_emit(SoundProp.Kind.TASER, pl.pos, -1)
	var hit := _nearest_on_segment(pl.pos, to)
	if hit >= 0:
		agents[hit].brain.on_hit(0, true, pl.pos)
	return hit


## Spoken command: goes to the nearest NPC inside the aim cone with a clear line.
func command(slot: int, cmd: int) -> Dictionary:
	var pl: PlayerState = players[slot]
	var cfg: Dictionary = _t["commands"]
	var best := -1
	var best_d := INF
	for i in agents.size():
		var a: Agent = agents[i]
		if a.dormant or not a.brain.alive() or a.brain.state == NpcBrain.State.RESTRAINED:
			continue
		if not Geom2D.cone_contains(pl.pos, pl.aim, float(cfg["cone_deg"]), float(cfg["range"]), a.pos):
			continue
		if not level.has_los(pl.pos, a.pos):
			continue
		var d := pl.pos.distance_to(a.pos)
		if d < best_d:
			best = i
			best_d = d
	if best < 0:
		return {"target": -1, "result": "none"}
	var target: Agent = agents[best]
	var seers := 0
	for q in players:
		if not q.dead() and q.pos.distance_to(target.pos) < 500.0 and level.has_los(q.pos, target.pos):
			seers += 1
	target.brain.pos = target.pos
	target.brain.set_outnumbered(seers >= 2)
	return {"target": best, "result": target.brain.on_command(cmd)}


func restrain_candidate(p: Vector2) -> int:
	var best := -1
	var best_d := float(_np["restrain_range"])
	for i in agents.size():
		var a: Agent = agents[i]
		if a.brain.restrainable() and p.distance_to(a.pos) <= best_d:
			best = i
			best_d = p.distance_to(a.pos)
	return best


func restrain(i: int) -> bool:
	return i >= 0 and i < agents.size() and agents[i].brain.restrain()


## The reinforcement wave arrives: every dormant agent starts heading for `target`.
func activate_reinforcements(target: Vector2) -> void:
	for a in agents:
		if a.dormant:
			a.dormant = false
			a.home = target
			a.brain.alert(target)


func count_state(role: int, state: int) -> int:
	var n := 0
	for a in agents:
		if a.brain.role == role and a.brain.state == state:
			n += 1
	return n


# ---- network packing ---------------------------------------------------------

func pack() -> Array:
	var ps := PackedVector2Array()
	var data := PackedInt32Array()
	var face := PackedFloat32Array()
	for a in agents:
		var b := a.brain
		ps.append(a.pos)
		face.append(b.facing)
		data.append(b.state | (16 if b.armed else 0) | (32 if b.feigning else 0) | (64 if b.had_weapon else 0) \
			| (128 if b.role == NpcBrain.Role.CIVILIAN else 0) | (b.hp << 8) | (65536 if a.dormant else 0) | (131072 if b.in_cover else 0) \
			| (262144 if b.aiming else 0))
	return [ps, data, face]


func unpack(ps: PackedVector2Array, data: PackedInt32Array, face: PackedFloat32Array) -> void:
	for i in mini(agents.size(), ps.size()):
		var a: Agent = agents[i]
		var b := a.brain
		var d := data[i]
		a.pos = ps[i]
		b.pos = a.pos
		b.facing = face[i]
		b.state = d & 15
		b.armed = (d & 16) != 0
		b.feigning = (d & 32) != 0
		b.hp = (d >> 8) & 255
		a.dormant = (d & 65536) != 0
		b.in_cover = (d & 131072) != 0
		b.aiming = (d & 262144) != 0


# ---- per-agent tick ------------------------------------------------------------

func _tick_agent(i: int, delta: float, sounds: Array[Dictionary], alerts: Array[Dictionary]) -> void:
	var a: Agent = agents[i]
	var b := a.brain
	if a.dormant or not b.alive() or b.state == NpcBrain.State.RESTRAINED:
		return
	b.pos = a.pos
	if b.needs_flee_target:
		b.flee_target = _pick_flee_target(a)
		b.needs_flee_target = false
	if b.needs_cover:
		b.set_cover(_pick_cover(a))
	if b.needs_ambush:
		var amb := _pick_ambush(a)
		b.set_ambush(amb[0], amb[1])
	_hear(i, a, sounds)
	if b.role == NpcBrain.Role.ENEMY:
		_see(a)
		_see_laser(a)
	var out := b.tick(delta)
	if out["scream"]:
		speech.emit("꺄악!", a.pos)  # the words first: a recorded scream replaces the synthesized one
		_emit(SoundProp.Kind.SCREAM, a.pos, i)
	var alert_at: Variant = out["alert_nearby"]
	if alert_at != null:
		alerts.append({"from": i, "pos": alert_at})
	var shoot_at: Variant = out["shoot"]
	if shoot_at != null:
		_npc_shoot(i, a)
	_move(i, a, out, delta)


func _hear(i: int, a: Agent, sounds: Array[Dictionary]) -> void:
	var mult := float(_diff["hearing_mult"]) if a.brain.role == NpcBrain.Role.ENEMY else 1.0
	var radii: Dictionary = _t["sound_radius"]
	var pen: Dictionary = _t["sound_penalty"]
	for s in sounds:
		if int(s["src"]) == i:
			continue
		var kind_name := SoundProp.NAMES[int(s["kind"])]
		var radius := float(radii[kind_name])
		var at: Vector2 = s["pos"]
		var dist := a.pos.distance_to(at)
		if dist > radius * mult:
			continue
		var blockers := level.blockers_between(at, a.pos)
		if SoundProp.is_heard(dist, blockers, pen, radius, mult):
			a.brain.hear(kind_name, at, SoundProp.loudness(dist, blockers, pen, radius, mult), level.room_at(at) != level.room_at(a.pos))


func _see(a: Agent) -> void:
	var best := -1
	var best_d := INF
	var seers := 0
	var half_fov := deg_to_rad(float(_diff["fov_deg"]) * 0.5)
	var close := float(_np["close_detect_range"])
	for s in players.size():
		var pl: PlayerState = players[s]
		if pl.dead():
			continue
		var d := a.pos.distance_to(pl.pos)
		if d > _detect_range(pl):
			continue
		if d > close and absf(angle_difference(a.brain.facing, (pl.pos - a.pos).angle())) > half_fov:
			continue
		if not level.has_los(a.pos, pl.pos):
			continue
		seers += 1
		if d < best_d:
			best = s
			best_d = d
	a.target_slot = best
	if best >= 0:
		a.brain.see_player(players[best].pos, seers >= 2)


func _detect_range(pl: PlayerState) -> float:
	var base := float(_diff["detect_range"])
	if level.is_dark(pl.pos) and not lit_by_flashlight(pl.pos):
		base = float(_np["dark_detect_range"])
	if pl.flash:
		base *= float(_np["flash_detect_mult"])
	return base


## Is point p inside any (visible) flashlight beam?
func lit_by_flashlight(p: Vector2) -> bool:
	var light: Dictionary = _t["light"]
	for q in players:
		if q.flash and not q.dead() \
				and Geom2D.cone_contains(q.pos, q.aim, float(light["flash_fov_deg"]), float(light["flash_range"]), p) \
				and level.has_los(q.pos, p):
			return true
	return false


func _see_laser(a: Agent) -> void:
	var half_fov := deg_to_rad(float(_diff["fov_deg"]) * 0.5)
	for pl in players:
		if not pl.laser or pl.dead():
			continue
		var dir := Vector2.from_angle(pl.aim)
		var end := pl.pos + dir * float(_t["laser_range"])
		var hit := level.ray_hit(pl.pos, end)
		var dot: Vector2 = hit["position"] if not hit.is_empty() else end
		if a.pos.distance_to(dot) > float(_np["laser_see_range"]):
			continue
		if absf(angle_difference(a.brain.facing, (dot - a.pos).angle())) > half_fov:
			continue
		if level.has_los(a.pos, dot - dir * 3.0):
			a.brain.see_laser(dot, pl.pos)
			return


func _npc_shoot(i: int, a: Agent) -> void:
	var slot := a.target_slot
	if slot < 0 or players[slot].dead():
		slot = _nearest_alive(a.pos)
	if slot < 0:
		return
	var pl: PlayerState = players[slot]
	var dir := (pl.pos - a.pos).normalized()
	var from := a.pos + dir * 18.0
	var dist := a.pos.distance_to(pl.pos)
	var chance := float(_diff["accuracy"]) * (1.0 - float(_np["hit_falloff"]) * clampf(dist / float(_diff["detect_range"]), 0.0, 1.0))
	chance = minf(chance * a.brain.aim_quality() * moving_target_mult(slot), 0.95)  # settled aim, still target: deadlier
	var hit := level.has_los(from, pl.pos) and _rng.randf() < chance
	var to := pl.pos
	var caught := {}
	if hit:  # the officer may stand behind low cover too
		caught = _cover_catch(from, pl.pos, false, {})
		if not caught.is_empty():
			hit = false
			to = caught["enter"]
	if not hit and caught.is_empty():
		var side := 1.0 if _rng.randf() < 0.5 else -1.0
		to = pl.pos + dir.orthogonal() * side * (25.0 + _rng.randf() * 35.0)
		var wall := level.ray_hit(from, to)
		if not wall.is_empty():
			to = wall["position"]
	_emit(SoundProp.Kind.GUNSHOT, a.pos, i)
	shot.emit(i, from, to)
	if hit:
		player_hit.emit(slot, i)


func _nearest_alive(p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for s in players.size():
		if not players[s].dead() and p.distance_to(players[s].pos) < best_d:
			best = s
			best_d = p.distance_to(players[s].pos)
	return best


## Alive NPC closest to `from` among those within hit_radius of segment from-to.
func _nearest_on_segment(from: Vector2, to: Vector2) -> int:
	var best := -1
	var best_t := INF
	var radius := float(_np["hit_radius"])
	for i in agents.size():
		var a: Agent = agents[i]
		if a.dormant or not a.brain.alive():
			continue
		var c := Geometry2D.get_closest_point_to_segment(a.pos, from, to)
		if c.distance_to(a.pos) <= radius and from.distance_to(c) < best_t:
			best = i
			best_t = from.distance_to(c)
	return best


func _share_alert(from: int, at: Vector2) -> void:
	var src: Agent = agents[from]
	var radius := float(_np["share_radius"])
	for j in agents.size():
		if j == from:
			continue
		var o: Agent = agents[j]
		var st := o.brain.state
		if o.dormant or o.brain.role != NpcBrain.Role.ENEMY:
			continue
		if st != NpcBrain.State.IDLE and st != NpcBrain.State.INVESTIGATE and st != NpcBrain.State.HIDE:
			continue
		if src.pos.distance_to(o.pos) > radius:
			continue
		var blockers := level.blockers_between(src.pos, o.pos)
		if int(blockers["walls"]) + int(blockers["closed"]) <= 1:
			o.brain.alert(at)


func _emit(kind: int, at: Vector2, source: int) -> void:
	on_sound(kind, at, source)
	sound_emitted.emit(kind, at)


# ---- movement ------------------------------------------------------------------

func _move(i: int, a: Agent, out: Dictionary, delta: float) -> void:
	var target: Variant = out["move_to"]
	if target == null:
		if a.brain.state == NpcBrain.State.IDLE and a.pos.distance_to(a.home) > ARRIVE_DIST * 2.0:
			target = a.home
		else:
			return
	var goal: Vector2 = target
	if a.pos.distance_to(goal) <= ARRIVE_DIST:
		_stop(a)
		return
	if a.path.is_empty() or a.path_goal.distance_to(goal) > 1.0:
		a.path = level.find_path(a.pos, goal)
		a.path_i = 0
		a.path_goal = goal
		if a.path.is_empty():
			_stop(a)
			return
	var speed := float(_np["run_speed"]) if out["run"] else float(_np["walk_speed"])
	var step := speed * delta
	var before := a.pos
	while step > 0.0 and a.path_i < a.path.size():
		var wp := a.path[a.path_i]
		var d := a.pos.distance_to(wp)
		if d <= step:
			a.pos = wp
			step -= d
			a.path_i += 1
		else:
			a.pos += (wp - a.pos) / d * step
			step = 0.0
	var moved := a.pos - before
	if moved.length_squared() > 0.0001 and MOVING_STATES.has(a.brain.state):
		a.brain.facing = moved.angle()
	_open_doors_near(i, a)
	if a.path_i >= a.path.size():
		_stop(a)


func _stop(a: Agent) -> void:
	a.path = PackedVector2Array()
	a.path_goal = Vector2.INF
	a.brain.arrived()


func _open_doors_near(i: int, a: Agent) -> void:
	for d in level.door_rects.size():
		if level.get_door_state(d) == Level.DoorState.OPEN or level.is_locked(d):
			continue
		if level.door_rects[d].grow(DOOR_TOUCH).has_point(a.pos):
			level.set_door_state(d, Level.DoorState.OPEN, 0)
			_emit(SoundProp.Kind.DOOR, level.door_rects[d].get_center(), i)
			doors_changed.emit()


## A spot crouched behind furniture, out of the nearest officer's line, within search_px: one of
## the points just round a piece (its sides and corners, behind_px out) with the piece between it
## and the officer, reachable and in the same room. The nearest such spot wins (hard cover before
## soft). Vector2.INF when there is none.
func _pick_cover(a: Agent) -> Vector2:
	var cc: Dictionary = _t["cover"]
	var threat := a.brain.target_pos
	var near := _nearest_alive(a.pos)
	if near >= 0:
		threat = players[near].pos
	var room := level.room_at(a.pos)
	var best := Vector2.INF
	var best_score := INF
	for pr in level.props:
		var kind: String = pr["cover"]
		if kind == "":
			continue
		var r: Rect2 = pr["rect"]
		if r.get_center().distance_to(a.pos) > float(cc["npc_search_px"]):
			continue
		var g := r.grow(float(cc["behind_px"]))
		var c := g.get_center()
		var core := r.grow(-minf(10.0, minf(r.size.x, r.size.y) * 0.3))  # the line must cross it well, not clip a corner
		for spot: Vector2 in [Vector2(c.x, g.position.y), Vector2(c.x, g.end.y), Vector2(g.position.x, c.y), Vector2(g.end.x, c.y),
				g.position, g.end, Vector2(g.end.x, g.position.y), Vector2(g.position.x, g.end.y)]:
			if spot.distance_to(threat) < float(cc["min_threat_px"]) or not Geom2D.segment_hits_rect(threat, spot, core):
				continue
			if room >= 0 and level.room_at(spot) != room:
				continue  # stay in the room: crossing doorways under fire is not taking cover
			if _spot_taken(a, spot):
				continue
			var score := a.pos.distance_to(spot) + (60.0 if kind == "soft" else 0.0)
			if score >= best_score:
				continue
			var path := level.find_path(a.pos, spot)
			if path.is_empty() or path[path.size() - 1].distance_to(spot) > 24.0:
				continue
			best_score = score
			best = spot
	return best


## Where to wait for officers coming from the sound it heard in another room: a spot in its own room
## that sees the way in (the first door on its path toward the sound) from 90..420 px, behind low
## furniture when it can, near where it stands. [spot, look]: spot INF to stay put; look is just
## inside that doorway (or the sound itself when there is no door between).
func _pick_ambush(a: Agent) -> Array:
	var room := level.room_at(a.pos)
	var door := _first_door_on(a.pos, level.find_path(a.pos, a.brain.target_pos))
	if room < 0 or door < 0:
		return [Vector2.INF, a.brain.target_pos]
	var r: Rect2 = level.rooms[room]["rect"]
	var dc := level.door_rects[door].get_center()
	var inside := dc + (r.get_center() - dc).normalized() * 24.0
	var behind := float(_t["cover"]["behind_px"])
	var cands: Array[Vector2] = [a.pos]
	var lows: Array[Rect2] = []
	for pr in level.props:
		var kind: String = pr["cover"]
		var pr_r: Rect2 = pr["rect"]
		if (kind != "hard" and kind != "soft") or not r.intersects(pr_r):
			continue
		lows.append(pr_r)
		var g := pr_r.grow(behind)
		var c := g.get_center()
		cands.append_array([Vector2(c.x, g.position.y), Vector2(c.x, g.end.y), Vector2(g.position.x, c.y), Vector2(g.end.x, c.y),
				g.position, g.end, Vector2(g.end.x, g.position.y), Vector2(g.position.x, g.end.y)])
	var inner := r.grow(-30.0)
	cands.append_array([inner.position, inner.end, Vector2(inner.end.x, inner.position.y), Vector2(inner.position.x, inner.end.y)])
	var best := Vector2.INF
	var best_score := INF
	for spot in cands:
		var d := spot.distance_to(inside)
		if level.room_at(spot) != room or d < 90.0 or d > 420.0 or (spot != a.pos and _spot_taken(a, spot)):
			continue
		var covered := false
		for low in lows:
			if Geom2D.segment_hits_rect(inside, spot, low.grow(-minf(6.0, minf(low.size.x, low.size.y) * 0.3))):
				covered = true
				break
		var score := a.pos.distance_to(spot) * 0.5 + (0.0 if covered else 90.0) + absf(d - 200.0) * 0.3
		if score >= best_score or not level.has_los(spot, inside):
			continue
		if spot != a.pos:
			var path := level.find_path(a.pos, spot)
			if path.is_empty() or path[path.size() - 1].distance_to(spot) > 24.0:
				continue
		best_score = score
		best = spot
	return [best, inside]


## The first door a walk from `from` along `path` goes through, or -1.
func _first_door_on(from: Vector2, path: PackedVector2Array) -> int:
	var prev := from
	for p in path:
		var hit := -1
		var hit_d := INF
		for d in level.door_rects.size():
			var dr := level.door_rects[d].grow(4.0)
			if Geom2D.segment_hits_rect(prev, p, dr) and prev.distance_to(dr.get_center()) < hit_d:
				hit = d
				hit_d = prev.distance_to(dr.get_center())
		if hit >= 0:
			return hit
		prev = p
	return -1


## Someone else already crouches there, or is on the way.
func _spot_taken(a: Agent, spot: Vector2) -> bool:
	for o in agents:
		if o == a or o.dormant or not o.brain.alive():
			continue
		if o.pos.distance_to(spot) < 26.0 or (o.brain.cover_target != Vector2.INF and o.brain.cover_target.distance_to(spot) < 26.0) \
				or (o.brain.ambush_spot != Vector2.INF and o.brain.ambush_spot.distance_to(spot) < 26.0):
			return true
	return false


func _pick_flee_target(a: Agent) -> Vector2:
	var best := a.pos
	var best_score := -INF
	for rm in level.rooms:
		var c := (rm["rect"] as Rect2).get_center()
		var nearest := INF
		for pl in players:
			if not pl.dead():
				nearest = minf(nearest, c.distance_to(pl.pos))
		if nearest == INF:
			nearest = 0.0
		var score := nearest - c.distance_to(a.pos) * 0.3 + _rng.randf() * 80.0
		if score > best_score and not level.find_path(a.pos, c).is_empty():
			best_score = score
			best = c
	return best
