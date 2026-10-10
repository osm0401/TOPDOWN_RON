class_name WeaponState
extends RefCounted
## One firearm: current magazine + spare magazines, each keeping its own round count.
## Pure logic (no nodes) so it can be tested headless. Numbers come from data/tuning.json.

var current := 0
var spares: Array[int] = []
var reloading := false
var fire_interval := 0.25
var reload_time := 1.6

var _cooldown := 0.0
var _reload_left := 0.0


static func create(mag_size: int, spare_mags: int, interval: float, reload_s: float) -> WeaponState:
	var w := WeaponState.new()
	w.current = mag_size
	for i in spare_mags:
		w.spares.append(mag_size)
	w.fire_interval = interval
	w.reload_time = reload_s
	return w


func try_fire() -> bool:
	if reloading or _cooldown > 0.0 or current <= 0:
		return false
	current -= 1
	_cooldown = fire_interval
	return true


## Starts a manual reload. Only worth it if some spare magazine holds more rounds.
func start_reload() -> bool:
	if reloading or _best_spare() < 0:
		return false
	reloading = true
	_reload_left = reload_time
	return true


## Advances timers. Returns true when a reload finished (state changed).
func update(delta: float) -> bool:
	_cooldown = maxf(_cooldown - delta, 0.0)
	if not reloading:
		return false
	_reload_left -= delta
	if _reload_left > 0.0:
		return false
	reloading = false
	var i := _best_spare()
	if i >= 0:
		var fresh := spares[i]
		spares[i] = current  # the old magazine keeps its remaining rounds
		current = fresh
	return true


func to_packed() -> PackedInt32Array:
	var out := PackedInt32Array([current, 1 if reloading else 0])
	out.append_array(PackedInt32Array(spares))
	return out


func from_packed(a: PackedInt32Array) -> void:
	if a.size() < 2:
		return
	current = a[0]
	reloading = a[1] == 1
	spares.clear()
	for i in range(2, a.size()):
		spares.append(a[i])


func _best_spare() -> int:
	var best := -1
	var best_rounds := current
	for i in spares.size():
		if spares[i] > best_rounds:
			best = i
			best_rounds = spares[i]
	return best
