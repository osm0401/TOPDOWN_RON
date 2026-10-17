class_name NpcBrain
extends RefCounted
## Pure NPC state machine (enemy + civilian). No nodes: the director feeds percepts
## (see/hear/laser/alert/command/hit) and applies the returned intents each tick.
##
## Enemy transitions (reason strings are shown in the debug overlay):
##   IDLE        -> SPOTTED (sees player) | INVESTIGATE (sound / ally alert) | INVESTIGATE (laser seen too long)
##   INVESTIGATE -> SPOTTED | IDLE (nothing found)
##   SPOTTED     -> THREAT (armed, after reaction time) | FLEE (unarmed) | INVESTIGATE (lost target)
##   THREAT      -> ATTACK (after telegraph time) | SURRENDER (command / suppression) | INVESTIGATE
##   ATTACK      -> INVESTIGATE (lost target) | SURRENDER (command / hurt / suppression)
##   SURRENDER   -> THREAT (only when feigning: attack cue) ; RESTRAINED via restrain()
##   FLEE        -> HIDE ; HIDE -> SPOTTED (sees player, armed) | IDLE
##   any         -> DOWN (stun) -> SURRENDER (unarmed) ; any -> DEAD
## Civilian: IDLE -> HIDE | FLEE (loud sound), commands -> DOWN | SURRENDER | FLEE.

enum Role { ENEMY, CIVILIAN }
enum State { IDLE, INVESTIGATE, SPOTTED, THREAT, ATTACK, SURRENDER, FLEE, HIDE, DOWN, RESTRAINED, DEAD }
enum Cmd { WEAPON_DROP, DOWN, FREEZE, TURN }

const STATE_NAMES: Array[String] = ["경계 전", "소리 확인", "발견", "위협", "공격", "항복", "도주", "숨음", "엎드림", "구속", "사망"]
const CMD_KEYS: Array[String] = ["weapon_drop", "down", "freeze", "turn"]
const LOUD_KINDS: Array[String] = ["gunshot", "kick", "scream", "taser"]

var role := Role.ENEMY
var state := State.IDLE
var hp := 3
var max_hp := 3
var armed := true
var had_weapon := true
var feigns := false          ## this enemy fakes surrender before attacking
var feigning := false
var stunned := false
var pos := Vector2.ZERO      ## set by the director every tick
var facing := 0.0
var target_pos := Vector2.ZERO
var flee_target := Vector2.ZERO
var needs_flee_target := false
var cover_target := Vector2.INF  ## where to crouch behind furniture (the director picks it when needs_cover)
var needs_cover := false
var in_cover := false             ## reached that spot: crouched behind it (shown, and harder to hit)
var reason := ""
var time_in_state := 0.0

var _p: Dictionary
var _rng: RandomNumberGenerator
var _timer := 0.0
var _fire_cd := 0.0
var _suppressed := 0.0
var _lost := 0.0
var _laser_t := 0.0
var _arrived := false
var _scream := false
var _alert_out := false
var _alert_target := Vector2.ZERO
var _feign_attack := false
var _outnumbered := false
var _sees := false
var _seen_pos := Vector2.ZERO
var _heard := false
var _heard_kind := ""
var _heard_pos := Vector2.ZERO
var _heard_loud := 0.0
var _laser_seen := false
var _laser_dot := Vector2.ZERO
var _laser_player := Vector2.ZERO
var _alerted := false
var _alert_pos := Vector2.ZERO


func _init(r: int, params: Dictionary, generator: RandomNumberGenerator, feign_type: bool = false) -> void:
	role = r
	_p = params
	_rng = generator
	feigns = feign_type
	if r == Role.ENEMY:
		hp = int(params["enemy_hp"])
	else:
		hp = int(params["civilian_hp"])
		armed = false
		had_weapon = false
	max_hp = hp


# ---- percepts (call before tick) -------------------------------------------

func see_player(at: Vector2, outnumbered_now: bool = false) -> void:
	_sees = true
	_seen_pos = at
	_outnumbered = outnumbered_now


func hear(kind: String, at: Vector2, loudness: float) -> void:
	if not _heard or loudness > _heard_loud:
		_heard = true
		_heard_kind = kind
		_heard_pos = at
		_heard_loud = loudness


func see_laser(dot: Vector2, player_at: Vector2) -> void:
	_laser_seen = true
	_laser_dot = dot
	_laser_player = player_at


func alert(at: Vector2) -> void:
	_alerted = true
	_alert_pos = at


func arrived() -> void:
	_arrived = true


func set_outnumbered(value: bool) -> void:
	_outnumbered = value


# ---- events ----------------------------------------------------------------

## Returns "comply", "refuse" or "ignored".
func on_command(cmd: int) -> String:
	if state == State.DEAD or state == State.RESTRAINED:
		return "ignored"
	if role == Role.CIVILIAN:
		if _rng.randf() < float(_p["civilian_chance"]):
			_go(State.DOWN if cmd == Cmd.DOWN else State.SURRENDER, "명령에 따름")
			return "comply"
		_go(State.FLEE, "명령을 거부하고 도망")
		return "refuse"
	if state == State.SURRENDER and feigning:
		if cmd == Cmd.WEAPON_DROP and _rng.randf() < 0.6:
			feigning = false
			armed = false
			reason = "무기를 버림 (진짜 항복)"
			return "comply"
		return "refuse"
	if state == State.SURRENDER or state == State.DOWN:
		return "ignored"
	if _rng.randf() < _comply_chance(cmd):
		_surrender("명령에 항복")
		return "comply"
	return "refuse"


func on_hit(damage: int, stun: bool, from: Vector2) -> void:
	if state == State.DEAD:
		return
	hp = maxi(hp - damage, 0)
	if hp <= 0:
		armed = false
		_go(State.DEAD, "사망")
		return
	if state == State.RESTRAINED:
		return
	if stun:
		stunned = true
		feigning = false
		armed = false
		_go(State.DOWN, "기절 (무기를 떨어뜨림)")
		return
	if damage <= 0:
		return
	if role == Role.CIVILIAN:
		_go(State.HIDE, "피격")
		return
	_alert_target = from
	target_pos = from
	if hp * 2 <= max_hp and _rng.randf() < float(_p["hurt_surrender_chance"]):
		_surrender("부상으로 항복")
	elif state == State.IDLE or state == State.INVESTIGATE or state == State.HIDE:
		_go(State.SPOTTED, "피격당함")


func on_threat_shot() -> void:
	if state == State.DEAD or state == State.RESTRAINED:
		return
	_suppressed = 4.0
	if role == Role.CIVILIAN:
		if state == State.IDLE:
			_go(State.HIDE, "위협 사격에 놀람")
		return
	if state == State.SPOTTED or state == State.THREAT or state == State.ATTACK:
		if _rng.randf() < float(_p["threat_shot_surrender_chance"]) * float(_p["compliance_mult"]):
			_surrender("위협 사격에 항복")
		elif state == State.ATTACK and not in_cover and armed:
			needs_cover = true  # shot at in the open: get behind something


func restrainable() -> bool:
	return not armed and not feigning and (state == State.SURRENDER or state == State.DOWN)


func restrain() -> bool:
	if not restrainable():
		return false
	_go(State.RESTRAINED, "구속됨")
	return true


func is_alert() -> bool:
	return state == State.SPOTTED or state == State.THREAT or state == State.ATTACK


func alive() -> bool:
	return state != State.DEAD


# ---- tick ------------------------------------------------------------------

## Intents: move_to (Vector2|null), run (bool), shoot (Vector2|null), scream (bool), alert_nearby (Vector2|null)
func tick(delta: float) -> Dictionary:
	var out := {"move_to": null, "run": false, "shoot": null, "scream": false, "alert_nearby": null}
	time_in_state += delta
	_suppressed = maxf(_suppressed - delta, 0.0)
	_fire_cd = maxf(_fire_cd - delta, 0.0)
	if state != State.DEAD and state != State.RESTRAINED:
		if role == Role.ENEMY:
			_tick_enemy(delta, out)
		else:
			_tick_civilian(delta, out)
	if _scream:
		out["scream"] = true
		_scream = false
	if _alert_out:
		out["alert_nearby"] = _alert_target
		_alert_out = false
	_clear_percepts()
	return out


func _tick_enemy(delta: float, out: Dictionary) -> void:
	match state:
		State.IDLE:
			if _sees:
				_alert_target = _seen_pos
				_go(State.SPOTTED, "플레이어를 발견")
			elif _alerted:
				target_pos = _alert_pos
				_go(State.INVESTIGATE, "동료의 경고를 받음")
			elif _heard:
				target_pos = _heard_pos
				_go(State.INVESTIGATE, "%s 소리를 들음" % _heard_kind)
			elif _laser_seen:
				facing = (_laser_dot - pos).angle()
				reason = "레이저를 봄"
				_laser_t += delta
				if _laser_t >= float(_p["laser_escalate_s"]):
					target_pos = _laser_player
					_alert_target = _laser_player
					_alert_out = true
					_go(State.INVESTIGATE, "레이저가 계속 비침")
			else:
				_laser_t = maxf(_laser_t - delta, 0.0)
		State.INVESTIGATE:
			if _sees:
				_alert_target = _seen_pos
				_go(State.SPOTTED, "수색 중 플레이어를 발견")
				return
			if _alerted:
				target_pos = _alert_pos
				_arrived = false
				_timer = 0.0
			elif _heard:
				target_pos = _heard_pos
				_arrived = false
				_timer = 0.0
			if _arrived:
				_timer += delta
				facing += delta * 1.5
				if _timer >= float(_p["search_s"]):
					_go(State.IDLE, "수색했지만 아무도 없음")
			else:
				out["move_to"] = target_pos
		State.SPOTTED:
			_track_player(delta)
			_timer -= delta
			if _timer <= 0.0:
				if armed:
					_go(State.THREAT, "무기를 겨눔")
				else:
					_go(State.FLEE, "무장이 없어 도주")
			elif _lost >= float(_p["lose_target_s"]):
				_go(State.INVESTIGATE, "발견했다가 놓침")
		State.THREAT:
			_track_player(delta)
			_timer -= delta
			if _timer <= 0.0:
				_feign_attack = false
				_go(State.ATTACK, "위협 후 공격")
			elif _lost >= float(_p["lose_target_s"]):
				_go(State.INVESTIGATE, "위협하다 놓침")
		State.ATTACK:
			_track_player(delta)
			if _sees and _fire_cd <= 0.0:
				out["shoot"] = _seen_pos
				_fire_cd = float(_p["fire_interval_s"]) * (float(_p.get("cover_fire_mult", 1.0)) if in_cover else 1.0)  # in cover: rises to fire now and then
			_take_cover(out)
			if _lost >= float(_p["lose_target_s"]):
				_go(State.INVESTIGATE, "목표를 놓침")
		State.SURRENDER:
			if feigning:
				_timer -= delta
				if _timer <= 0.0:
					feigning = false
					_feign_attack = true
					_go(State.THREAT, "항복한 척하다가 공격 준비")
		State.FLEE:
			_flee(delta, out)
		State.HIDE:
			_timer -= delta
			_take_cover(out)
			if armed and _sees:
				_alert_target = _seen_pos
				_go(State.SPOTTED, "엄폐 중 플레이어를 발견")
			elif _timer <= 0.0:
				_go(State.IDLE, "진정됨")
		State.DOWN:
			if stunned:
				_timer -= delta
				if _timer <= 0.0:
					stunned = false
					_go(State.SURRENDER, "기절에서 깨어남 (무장 없음)")


func _tick_civilian(delta: float, out: Dictionary) -> void:
	var loud := _heard and LOUD_KINDS.has(_heard_kind) and _heard_loud > 0.1
	match state:
		State.IDLE:
			if loud:
				if _rng.randf() < float(_p["civilian_flee_chance"]):
					_go(State.FLEE, "총성에 놀라 도망")
				else:
					_go(State.HIDE, "총성에 놀라 숨음")
		State.HIDE:
			if loud:
				_timer = float(_p["hide_s"])
			_timer -= delta
			_take_cover(out)
			if _timer <= 0.0:
				_go(State.IDLE, "진정됨")
		State.FLEE:
			_flee(delta, out)


func _flee(delta: float, out: Dictionary) -> void:
	_timer -= delta
	if not needs_flee_target:
		out["move_to"] = flee_target
		out["run"] = true
	if _arrived or _timer <= 0.0:
		_go(State.HIDE, "도주 끝, 숨음")


## The director's answer to needs_cover: where to crouch (Vector2.INF: nowhere, stay put).
func set_cover(spot: Vector2) -> void:
	cover_target = spot
	needs_cover = false
	in_cover = false
	_arrived = false


## Runs to the cover spot the director picked, then stays crouched there.
func _take_cover(out: Dictionary) -> void:
	if in_cover:
		if not _sees and target_pos.distance_to(pos) > 1.0:
			facing = (target_pos - pos).angle()  # crouched, watching where the threat was
		return
	if cover_target == Vector2.INF or needs_cover:
		return
	if _arrived:
		in_cover = true
		return
	out["move_to"] = cover_target
	out["run"] = true


func _track_player(delta: float) -> void:
	if _sees:
		target_pos = _seen_pos
		_lost = 0.0
		facing = (_seen_pos - pos).angle()
	else:
		_lost += delta


func _surrender(why: String) -> void:
	if feigns and armed and not feigning:
		feigning = true
		_go(State.SURRENDER, why + " (항복하는 척)")
	else:
		_go(State.SURRENDER, why)


func _comply_chance(cmd: int) -> float:
	var base: Dictionary = _p["chance"]
	var c := float(base[CMD_KEYS[cmd]]) * float(_p["compliance_mult"])
	if _suppressed > 0.0:
		c += float(_p["suppressed_bonus"])
	if hp * 2 <= max_hp:
		c += float(_p["hurt_bonus"])
	if _outnumbered:
		c += float(_p["outnumbered_bonus"])
	if state == State.ATTACK:
		c *= float(_p["engaged_mult"])
	return clampf(c, 0.0, 0.95)


func _go(s: int, why: String) -> void:
	state = s
	reason = why
	time_in_state = 0.0
	_arrived = false
	_laser_t = 0.0
	in_cover = false
	cover_target = Vector2.INF
	needs_cover = (s == State.ATTACK and armed) or s == State.HIDE
	match s:
		State.SPOTTED:
			_timer = float(_p["react_time"])
			_lost = 0.0
			_alert_out = true
		State.THREAT:
			_timer = float(_p["feign_threat_s"]) if _feign_attack else float(_p["threat_time_s"])
			_lost = 0.0
		State.ATTACK:
			_fire_cd = 0.25
			_lost = 0.0
		State.SURRENDER:
			if feigning:
				_timer = float(_p["feign_s"])
			else:
				armed = false
		State.FLEE:
			needs_flee_target = true
			_timer = float(_p["flee_s"])
		State.HIDE:
			_timer = float(_p["hide_s"])
			if role == Role.CIVILIAN:
				_scream = true
		State.DOWN:
			if stunned:
				_timer = float(_p["stun_s"])
		State.DEAD:
			armed = false


func _clear_percepts() -> void:
	_sees = false
	_heard = false
	_heard_loud = 0.0
	_laser_seen = false
	_alerted = false
