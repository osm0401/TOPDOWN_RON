class_name Geom2D
extends RefCounted
## Small pure geometry helpers (no nodes, testable headless).


## Liang-Barsky: does segment a-b touch rectangle r?
static func segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	var p: Array[float] = [-d.x, d.x, -d.y, d.y]
	var q: Array[float] = [a.x - r.position.x, r.end.x - a.x, a.y - r.position.y, r.end.y - a.y]
	for i in 4:
		if is_zero_approx(p[i]):
			if q[i] < 0.0:
				return false
		else:
			var t: float = q[i] / p[i]
			if p[i] < 0.0:
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
