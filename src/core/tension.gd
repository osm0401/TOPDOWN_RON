class_name TensionMeter
extends RefCounted
## How tense the moment is, 0 calm .. 1 the worst of a fight. Drives the music layers.
## Events (shots, being hit) push it up at once and hold it a while; the situation sets a
## floor (enemies that know you are there); after the hold it sinks slowly to that floor.
## Pure: no nodes, tested headless.

var level := 0.0  ## eased value the music follows
var rise_per_s := 1.5
var fall_per_s := 0.06
var hold_s := 6.0
var _spike := 0.0  ## strongest recent event
var _hold := 0.0


func configure(cfg: Dictionary) -> void:
	rise_per_s = float(cfg.get("rise_per_s", rise_per_s))
	fall_per_s = float(cfg.get("fall_per_s", fall_per_s))
	hold_s = float(cfg.get("hold_s", hold_s))


## Something happened (0..1); the stronger of it and what is already held wins.
func bump(amount: float) -> void:
	_spike = maxf(_spike, clampf(amount, 0.0, 1.0))
	_hold = hold_s


func update(delta: float, floor_level: float) -> void:
	if _hold > 0.0:
		_hold -= delta
	else:
		_spike = move_toward(_spike, 0.0, fall_per_s * delta)
	var target := maxf(clampf(floor_level, 0.0, 1.0), _spike)
	level = move_toward(level, target, (rise_per_s if target > level else fall_per_s) * delta)


## Volume (0..1) of a layer that starts at `from` and is full at `full` (levels).
static func layer_gain(lvl: float, from: float, full: float) -> float:
	if full <= from:
		return 1.0 if lvl >= from else 0.0
	return smoothstep(from, full, lvl)
