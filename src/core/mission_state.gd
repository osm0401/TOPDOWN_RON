class_name MissionState
extends RefCounted
## Mission phases and objective/failure rules (pure, no nodes).
##   BRIEFING -> ACTIVE (both players ready) -> RESULT (success or failure).
## Required objectives: [0] suspect captured alive (restrained), [1] every living civilian
## restrained, [2] every non-suspect enemy dead or restrained, [3] back in the exit zone
## (all living players) once [0..2] are done.
## Failure: the suspect is killed, or both players are dead. A civilian death only costs score.

enum Phase { BRIEFING, ACTIVE, RESULT }
enum Status { ACTIVE, SUCCESS, FAILED }

const REASON_KEYS: Array[String] = ["", "suspect_killed", "all_dead"]

var phase := Phase.BRIEFING
var status := Status.ACTIVE
var reason := 0
var civ_killed := 0
var suspect_killed := 0
var enemy_killed := 0
var objectives: Array[bool] = [false, false, false, false]
var ready: Array[bool] = [false, false]


func reason_key() -> String:
	return REASON_KEYS[reason]


## Returns true when the state changed.
func mark_ready(slot: int) -> bool:
	if phase != Phase.BRIEFING or ready[slot]:
		return false
	ready[slot] = true
	if ready[0] and ready[1]:
		phase = Phase.ACTIVE
	return true


## snap: suspect_restrained, suspect_dead (bool); civ_unrestrained_alive, enemies_pending,
## players_alive, players_in_exit (int). Returns true when anything changed.
func evaluate(snap: Dictionary) -> bool:
	if phase != Phase.ACTIVE:
		return false
	var before := pack()
	var alive := int(snap["players_alive"])
	objectives[0] = bool(snap["suspect_restrained"])
	objectives[1] = int(snap["civ_unrestrained_alive"]) == 0
	objectives[2] = int(snap["enemies_pending"]) == 0
	objectives[3] = objectives[0] and objectives[1] and objectives[2] and alive > 0 \
			and int(snap["players_in_exit"]) == alive
	if bool(snap["suspect_dead"]):
		_finish(Status.FAILED, 1)
	elif alive == 0:
		_finish(Status.FAILED, 2)
	elif objectives[3]:
		_finish(Status.SUCCESS, 0)
	return pack() != before


func _finish(new_status: int, why: int) -> void:
	status = new_status
	reason = why
	phase = Phase.RESULT


## [phase, status, reason, civ_killed, suspect_killed, enemy_killed, objective bits, ready bits]
func pack() -> PackedInt32Array:
	var obj := 0
	for i in objectives.size():
		if objectives[i]:
			obj |= 1 << i
	return PackedInt32Array([phase, status, reason, civ_killed, suspect_killed, enemy_killed,
			obj, (1 if ready[0] else 0) | (2 if ready[1] else 0)])


func unpack(a: PackedInt32Array) -> void:
	if a.size() < 8:
		return
	phase = a[0]
	status = a[1]
	reason = a[2]
	civ_killed = a[3]
	suspect_killed = a[4]
	enemy_killed = a[5]
	for i in objectives.size():
		objectives[i] = (a[6] & (1 << i)) != 0
	ready[0] = (a[7] & 1) != 0
	ready[1] = (a[7] & 2) != 0
