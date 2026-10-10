class_name Level
extends Node2D
## Gray-box map: walls and doors as physics bodies built from data/map_01.json.
## Used for player collision (host), line-of-sight / bullet rays and the fog polygon.
## Closed doors block movement and rays; open doors do not.

const WALL_LAYER := 1
const RAY_EPS := 0.0001
const ARC_RAYS := 24
const FRAME_THICKNESS := 50.0

var bounds := Rect2()
var building := Rect2()
var exit_zone := Rect2()
var npc_pos := Vector2.ZERO
var spawns: Array[Vector2] = []
var wall_rects: Array[Rect2] = []
var door_rects: Array[Rect2] = []
var door_actor: Array[int] = []  ## who toggled last: 0 nobody, 1 host, 2 client

var _door_open: Array[bool] = []
var _door_shapes: Array[CollisionShape2D] = []
var _corners := PackedVector2Array()


func load_map(path: String) -> bool:
	var d := JsonData.load_dict(path)
	if d.is_empty():
		return false
	bounds = _rect(d["bounds"])
	building = _rect(d["building"])
	exit_zone = _rect(d["exit_zone"])
	npc_pos = _vec(d["npc"])
	for s in d["spawns"]:
		spawns.append(_vec(s))
	for w in d["walls"]:
		var r := _rect(w)
		wall_rects.append(r)
		_add_body(r)
		_add_corners(r)
	for f in _frame(bounds):
		_add_body(f)
	for dd in d["doors"]:
		var r := _rect(dd["rect"])
		door_rects.append(r)
		door_actor.append(0)
		_door_open.append(false)
		_door_shapes.append(_add_body(r))
		_add_corners(r)
	return true


func is_door_open(i: int) -> bool:
	return _door_open[i]


func toggle_door(i: int, actor: int) -> void:
	_set_open(i, not _door_open[i])
	door_actor[i] = actor


## Index of the door whose rectangle is closest to p within max_dist, or -1.
func nearest_door(p: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for i in door_rects.size():
		var r := door_rects[i]
		var c := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		var d := p.distance_to(c)
		if d <= best_d:
			best = i
			best_d = d
	return best


func pack_doors() -> PackedInt32Array:
	var open_bits := 0
	var actor_bits := 0
	for i in door_rects.size():
		if _door_open[i]:
			open_bits |= 1 << i
		actor_bits |= door_actor[i] << (2 * i)
	return PackedInt32Array([open_bits, actor_bits])


func unpack_doors(a: PackedInt32Array) -> void:
	if a.size() < 2:
		return
	for i in door_rects.size():
		_set_open(i, ((a[0] >> i) & 1) == 1)
		door_actor[i] = (a[1] >> (2 * i)) & 3


## First wall/closed-door hit on the segment, {} if clear. Needs the node in the tree.
func ray_hit(from: Vector2, to: Vector2) -> Dictionary:
	var q := PhysicsRayQueryParameters2D.create(from, to, WALL_LAYER)
	return get_world_2d().direct_space_state.intersect_ray(q)


func has_los(a: Vector2, b: Vector2) -> bool:
	return ray_hit(a, b).is_empty()


## Star-shaped area visible from origin (walls + closed doors), limited to radius.
func visibility_polygon(origin: Vector2, radius: float) -> PackedVector2Array:
	var angles: Array[float] = []
	var r2 := radius * radius
	for c in _corners:
		var d := c - origin
		if d.length_squared() > r2:
			continue
		var a := d.angle()
		angles.append(a - RAY_EPS)
		angles.append(a)
		angles.append(a + RAY_EPS)
	for i in ARC_RAYS:
		angles.append(TAU * i / ARC_RAYS - PI)
	angles.sort()
	var pts := PackedVector2Array()
	for a in angles:
		var to := origin + Vector2.from_angle(a) * radius
		var hit := ray_hit(origin, to)
		pts.append(hit["position"] if not hit.is_empty() else to)
	return pts


func _set_open(i: int, open: bool) -> void:
	_door_open[i] = open
	_door_shapes[i].disabled = open


func _add_body(r: Rect2) -> CollisionShape2D:
	var body := StaticBody2D.new()
	body.collision_layer = WALL_LAYER
	body.collision_mask = 0
	body.position = r.get_center()
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = r.size
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	return cs


func _add_corners(r: Rect2) -> void:
	_corners.append(r.position)
	_corners.append(Vector2(r.end.x, r.position.y))
	_corners.append(r.end)
	_corners.append(Vector2(r.position.x, r.end.y))


func _frame(b: Rect2) -> Array[Rect2]:
	var t := FRAME_THICKNESS
	return [
		Rect2(b.position.x - t, b.position.y - t, b.size.x + 2 * t, t),
		Rect2(b.position.x - t, b.end.y, b.size.x + 2 * t, t),
		Rect2(b.position.x - t, b.position.y, t, b.size.y),
		Rect2(b.end.x, b.position.y, t, b.size.y),
	]


static func _rect(a: Array) -> Rect2:
	return Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3]))


static func _vec(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))
