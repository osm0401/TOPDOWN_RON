class_name ReinforcementClock
extends RefCounted
## Countdown to the single reinforcement wave (pure). Loud noise and alarms move the
## arrival earlier, but the warning always comes first and leaves a minimum lead time.
##   WAITING --(remaining <= min_warning)--> WARNED --(remaining <= 0)--> ARRIVED

enum Phase { WAITING, WARNED, ARRIVED }

var phase := Phase.WAITING
var remaining := 300.0
var min_warning := 8.0
var min_lead_after_noise := 2.0


func _init(delay_s: float = 300.0, min_warning_s: float = 8.0, min_lead_s: float = 2.0) -> void:
	remaining = delay_s
	min_warning = min_warning_s
	min_lead_after_noise = min_lead_s


## Advances the clock. Returns "" | "warning" | "arrive". Time that would skip the warning
## is clamped so the warning is always given at least `min_warning` before arrival.
func tick(delta: float) -> String:
	if phase == Phase.ARRIVED:
		return ""
	remaining -= delta
	if phase == Phase.WAITING:
		if remaining <= min_warning:
			phase = Phase.WARNED
			remaining = min_warning
			return "warning"
		return ""
	if remaining <= 0.0:
		phase = Phase.ARRIVED
		remaining = 0.0
		return "arrive"
	return ""


## A loud event: pulls the arrival earlier. After the warning it never cuts the lead
## below `min_lead_after_noise`.
func add_noise(seconds: float) -> void:
	if phase == Phase.ARRIVED or seconds <= 0.0:
		return
	if phase == Phase.WAITING:
		remaining = maxf(remaining - seconds, 0.0)
	else:
		remaining = maxf(remaining - seconds, minf(min_lead_after_noise, remaining))
