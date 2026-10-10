class_name VoteState
extends RefCounted
## Result-screen vote: retry the same mission or return to the main lobby (pure).
## Both present players must pick the same option. If they differ (or time runs out)
## there is one more round; if they still differ the outcome is the lobby.
## A single player (solo) decides alone and has no timer.

enum Choice { NONE, RETRY, LOBBY }
enum Outcome { PENDING, RETRY, LOBBY }

var votes: Array[int] = [Choice.NONE, Choice.NONE]
var present: Array[bool] = [true, true]
var round_no := 1
var time_left := 15.0
var outcome := Outcome.PENDING
var round_s := 15.0
var max_rounds := 2
var timed := true


func _init(round_seconds: float = 15.0, rounds: int = 2) -> void:
	round_s = round_seconds
	max_rounds = rounds
	time_left = round_seconds


## Starts a fresh vote for the given set of present players.
func start(present_players: Array[bool], with_timer: bool) -> void:
	present = present_players.duplicate()
	timed = with_timer
	votes = [Choice.NONE, Choice.NONE]
	round_no = 1
	time_left = round_s
	outcome = Outcome.PENDING


## Records a vote. Returns true when something changed.
func cast(slot: int, choice: int) -> bool:
	if outcome != Outcome.PENDING or not present[slot] or votes[slot] != Choice.NONE:
		return false
	if choice != Choice.RETRY and choice != Choice.LOBBY:
		return false
	votes[slot] = choice
	_resolve()
	return true


## Advances the round timer. Returns true when something changed.
func tick(delta: float) -> bool:
	if outcome != Outcome.PENDING or not timed:
		return false
	time_left -= delta
	if time_left > 0.0:
		return false
	time_left = 0.0
	_end_round()
	return true


func _resolve() -> void:
	for s in 2:
		if present[s] and votes[s] == Choice.NONE:
			return
	_end_round()


func _end_round() -> void:
	var agreed := Choice.NONE
	var same := true
	for s in 2:
		if not present[s]:
			continue
		if votes[s] == Choice.NONE:
			same = false
		elif agreed == Choice.NONE:
			agreed = votes[s]
		elif agreed != votes[s]:
			same = false
	if same and agreed != Choice.NONE:
		outcome = Outcome.RETRY if agreed == Choice.RETRY else Outcome.LOBBY
	elif round_no < max_rounds:
		round_no += 1
		votes = [Choice.NONE, Choice.NONE]
		time_left = round_s
	else:
		outcome = Outcome.LOBBY


## [outcome, round, vote0, vote1, time_left*10]
func pack() -> PackedInt32Array:
	return PackedInt32Array([outcome, round_no, votes[0], votes[1], int(time_left * 10.0)])


func unpack(a: PackedInt32Array) -> void:
	if a.size() < 5:
		return
	outcome = a[0]
	round_no = a[1]
	votes = [a[2], a[3]]
	time_left = a[4] / 10.0
