class_name Geom2D
extends RefCounted
## Small pure geometry helpers (no nodes, testable headless).


## Liang-Barsky: does segment a-b touch rectangle r? (Runs for every wall on every sound an NPC or
## the listener may hear: no arrays are built.)
static func segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	var e := r.end
	for i in 4:  # left, right, top, bottom side
		var p := -d.x if i == 0 else (d.x if i == 1 else (-d.y if i == 2 else d.y))
		var q := a.x - r.position.x if i == 0 else (e.x - a.x if i == 1 else (a.y - r.position.y if i == 2 else e.y - a.y))
		if is_zero_approx(p):
			if q < 0.0:
				return false
		else:
			var t := q / p
			if p < 0.0:
				if t > t1:
					return false
				t0 = maxf(t0, t)
			else:
				if t < t0:
					return false
				t1 = minf(t1, t)
	return true


## Is p inside the cone (origin, aim angle, full fov in degrees, range)?
static func cone_contains(origin: Vector2, aim: float, fov_deg: float, max_range: float, p: Vector2) -> bool:
	var d := p - origin
	if d.length() > max_range:
		return false
	if d.is_zero_approx():
		return true
	return absf(angle_difference(aim, d.angle())) <= deg_to_rad(fov_deg * 0.5)


static func rect_corners(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	])
