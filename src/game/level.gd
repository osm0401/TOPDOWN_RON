class_name Level
extends Node2D
## Gray-box map built from data/map_01.json: wall/door physics bodies, door states
## (closed / ajar / open + locked), rooms with lighting, sound blockers, rays, fog polygon
## and an A* grid for NPCs. Closed doors block movement and rays; an ajar door leaves a
## narrow slit (rays pass, bodies do not); open doors block nothing.

enum DoorState { CLOSED, AJAR, OPEN }

const WALL_LAYER := 1
const RAY_EPS := 0.0001
const ARC_RAYS := 24
const FRAME_THICKNESS := 50.0
const AJAR_GAP := 12.0
const CELL := 20.0
const NAV_INFLATE := 14.0

var bounds := Rect2()
var building := Rect2()
var exit_zone := Rect2()
var spawns: Array[Vector2] = []
var wall_rects: Array[Rect2] = []
var door_rects: Array[Rect2] = []
var door_actor: Array[int] = []        ## who touched the door last: 0 nobody/NPC, 1 host, 2 client
var rooms: Array[Dictionary] = []      ## {name, rect, dark}
var npc_defs: Array[Dictionary] = []   ## {role, pos, facing, feigns}

var _door_state: Array[int] = []
var _door_locked: Array[bool] = []
var _door_shapes: Array[CollisionShape2D] = []
var _door_corners: Array[PackedVector2Array] = []
var _corners := PackedVector2Array()
var _grid: AStarGrid2D


func load_map(path: String) -> bool:
	var d := JsonData.load_dict(path)
	if d.is_empty():
		return false
	bounds = _rect(d["bounds"])
	building = _rect(d["building"])
	exit_zone = _rect(d["exit_zone"])
	for s in d["spawns"]:
		spawns.append(_vec(s))
	for rm in d["rooms"]:
		rooms.append({"name": str(rm["name"]), "rect": _rect(rm["rect"]), "dark": bool(rm["dark"])})
	for n in d["npcs"]:
		npc_defs.append({
			"role": str(n["role"]),
			"pos": _vec(n["pos"]),
			"facing": float(n.get("facing", 0.0)),
			"feigns": bool(n.get("feigns", false)),
			"suspect": bool(n.get("suspect", false)),
			"reinforcement": bool(n.get("reinforcement", false)),
			"clues": n.get("clues", []),
		})
	for w in d["walls"]:
		var r := _rect(w)
		wall_rects.append(r)
		_add_body(r)
		_corners.append_array(Geom2D.rect_corners(r))
	for f in _frame(bounds):
		_add_body(f)
	for dd in d["doors"]:
		var r := _rect(dd["rect"])
		door_rects.append(r)
		door_actor.append(0)
		_door_state.append(DoorState.CLOSED)
		_door_locked.append(bool(dd.get("locked", false)))
		_door_shapes.append(_add_body(r))
		_door_corners.append(Geom2D.rect_corners(r))
	build_grid()
	return true


# ---- doors -----------------------------------------------------------------

func get_door_state(i: int) -> int:
	return _door_state[i]


func is_door_open(i: int) -> bool:
	return _door_state[i] == DoorState.OPEN


func is_locked(i: int) -> bool:
	return _door_locked[i]


func set_locked(i: int, locked: bool) -> void:
	_door_locked[i] = locked
	_refresh_door_cells(i)


func set_door_state(i: int, state: int, actor: int) -> void:
	_door_state[i] = state
	door_actor[i] = actor
	_apply_door(i)
	_refresh_door_cells(i)


## Normal open/close. Returns false when a locked closed door refuses.
func toggle_door(i: int, actor: int) -> bool:
	if _door_state[i] == DoorState.OPEN:
		set_door_state(i, DoorState.CLOSED, actor)
		return true
	if _door_locked[i] and _door_state[i] == DoorState.CLOSED:
		return false
	set_door_state(i, DoorState.OPEN, actor)
	return true


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


## Rectangle that currently blocks (closed: full, ajar: shortened); empty Rect2 when open.
func door_collider_rect(i: int) -> Rect2:
	var r := door_rects[i]
	match _door_state[i]:
		DoorState.OPEN:
			return Rect2()
		DoorState.AJAR:
			return Rect2(r.position, r.size - (Vector2(AJAR_GAP, 0) if _horizontal(i) else Vector2(0, AJAR_GAP)))
	return r


## Where a door camera sits: just past the door, on the side away from `from`.
func door_cam_origin(i: int, from: Vector2) -> Vector2:
	var r := door_rects[i]
	var c := r.get_center()
	var n := Vector2(0, 1) if _horizontal(i) else Vector2(1, 0)
	var side := 1.0 if (from - c).dot(n) >= 0.0 else -1.0
	var half := (r.size.y if _horizontal(i) else r.size.x) * 0.5
	return c - n * side * (half + 6.0)


func pack_doors() -> PackedInt32Array:
	var state_bits := 0
	var actor_bits := 0
	var locked_bits := 0
	for i in door_rects.size():
		state_bits |= _door_state[i] << (2 * i)
		actor_bits |= door_actor[i] << (2 * i)
		if _door_locked[i]:
			locked_bits |= 1 << i
	return PackedInt32Array([state_bits, actor_bits, locked_bits])


func unpack_doors(a: PackedInt32Array) -> void:
	if a.size() < 3:
		return
	for i in door_rects.size():
		var s := (a[0] >> (2 * i)) & 3
		var locked := ((a[2] >> i) & 1) == 1
		var actor := (a[1] >> (2 * i)) & 3
		if s != _door_state[i] or locked != _door_locked[i] or actor != door_actor[i]:
			_door_state[i] = s
			_door_locked[i] = locked
			door_actor[i] = actor
			_apply_door(i)
			_refresh_door_cells(i)


# ---- rooms / light ---------------------------------------------------------

func room_at(p: Vector2) -> int:
	for i in rooms.size():
		if (rooms[i]["rect"] as Rect2).has_point(p):
			return i
	return -1


func is_dark(p: Vector2) -> bool:
	var i := room_at(p)
	return i >= 0 and bool(rooms[i]["dark"])


# ---- rays / sight / sound --------------------------------------------------

## First wall/closed-door hit on the segment, {} if clear. Needs the node in the tree.
func ray_hit(from: Vector2, to: Vector2) -> Dictionary:
	var q := PhysicsRayQueryParameters2D.create(from, to, WALL_LAYER)
	return get_world_2d().direct_space_state.intersect_ray(q)


func has_los(a: Vector2, b: Vector2) -> bool:
	return ray_hit(a, b).is_empty()


## Walls / closed doors / ajar doors the straight segment a-b passes through (pure math).
func blockers_between(a: Vector2, b: Vector2) -> Dictionary:
	var walls := 0
	var closed := 0
	var ajar := 0
	for r in wall_rects:
		if Geom2D.segment_hits_rect(a, b, r):
			walls += 1
	for i in door_rects.size():
		if _door_state[i] == DoorState.OPEN:
			continue
		if Geom2D.segment_hits_rect(a, b, door_collider_rect(i)):
			if _door_state[i] == DoorState.CLOSED:
				closed += 1
			else:
				ajar += 1
	return {"walls": walls, "closed": closed, "ajar": ajar}


## Star-shaped area visible from origin (walls + closed/ajar doors), limited to radius.
func visibility_polygon(origin: Vector2, radius: float) -> PackedVector2Array:
	var angles: Array[float] = []
	_add_corner_angles(angles, _corners, origin, radius)
	for dc in _door_corners:
		_add_corner_angles(angles, dc, origin, radius)
	for i in ARC_RAYS:
		angles.append(TAU * i / ARC_RAYS - PI)
	angles.sort()
	return _cast(origin, angles, radius)


## Visible part of a cone (flashlight): fan polygon [origin, hit, hit, ...].
func cone_polygon(origin: Vector2, aim: float, fov_deg: float, radius: float) -> PackedVector2Array:
	var half := deg_to_rad(fov_deg * 0.5)
	var angles: Array[float] = [aim - half, aim + half]
	var tmp: Array[float] = []
	_add_corner_angles(tmp, _corners, origin, radius)
	for dc in _door_corners:
		_add_corner_angles(tmp, dc, origin, radius)
	for a in tmp:
		if absf(angle_difference(aim, a)) < half:
			angles.append(aim + angle_difference(aim, a))
	for i in 9:
		angles.append(aim - half + 2.0 * half * i / 8.0)
	angles.sort()
	var pts := PackedVector2Array([origin])
	pts.append_array(_cast(origin, angles, radius))
	return pts


# ---- navigation ------------------------------------------------------------

func build_grid() -> void:
	var cols := int(ceil(bounds.size.x / CELL))
	var rows := int(ceil(bounds.size.y / CELL))
	_grid = AStarGrid2D.new()
	_grid.region = Rect2i(0, 0, cols, rows)
	_grid.cell_size = Vector2(CELL, CELL)
	_grid.offset = Vector2(CELL * 0.5, CELL * 0.5)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.update()
	for x in cols:
		for y in rows:
			var c := Vector2i(x, y)
			if _cell_blocked(c):
				_grid.set_point_solid(c, true)


## Waypoints from a to b around walls/locked doors; empty when unreachable.
func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a := _free_cell(from)
	var b := _free_cell(to)
	if a.x < 0 or b.x < 0:
		return PackedVector2Array()
	return _grid.get_point_path(a, b)


func _free_cell(p: Vector2) -> Vector2i:
	var region := _grid.region
	var c := Vector2i(clampi(int(floor(p.x / CELL)), 0, region.size.x - 1), clampi(int(floor(p.y / CELL)), 0, region.size.y - 1))
	if not _grid.is_point_solid(c):
		return c
	for ring in range(1, 5):
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				var n := c + Vector2i(dx, dy)
				if region.has_point(n) and not _grid.is_point_solid(n):
					return n
	return Vector2i(-1, -1)


func _cell_blocked(c: Vector2i) -> bool:
	var center := (Vector2(c) + Vector2(0.5, 0.5)) * CELL
	for r in wall_rects:
		if r.grow(NAV_INFLATE).has_point(center):
			return true
	for i in door_rects.size():
		if _door_locked[i] and _door_state[i] != DoorState.OPEN and door_rects[i].grow(NAV_INFLATE).has_point(center):
			return true
	return false


func _refresh_door_cells(i: int) -> void:
	if _grid == null:
		return
	var r := door_rects[i].grow(NAV_INFLATE + CELL)
	var x0 := maxi(int(floor(r.position.x / CELL)), 0)
	var y0 := maxi(int(floor(r.position.y / CELL)), 0)
	var x1 := mini(int(ceil(r.end.x / CELL)), _grid.region.size.x - 1)
	var y1 := mini(int(ceil(r.end.y / CELL)), _grid.region.size.y - 1)
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			var c := Vector2i(x, y)
			_grid.set_point_solid(c, _cell_blocked(c))


# ---- internals -------------------------------------------------------------

func _horizontal(i: int) -> bool:
	return door_rects[i].size.x >= door_rects[i].size.y


func _apply_door(i: int) -> void:
	var cs := _door_shapes[i]
	var shape := cs.shape as RectangleShape2D
	if _door_state[i] == DoorState.OPEN:
		cs.disabled = true
		_door_corners[i] = PackedVector2Array()
		return
	cs.disabled = false
	var r := door_rects[i]
	var size := r.size
	var offset := Vector2.ZERO
	if _door_state[i] == DoorState.AJAR:
		if _horizontal(i):
			size.x -= AJAR_GAP
			offset.x = -AJAR_GAP * 0.5
		else:
			size.y -= AJAR_GAP
			offset.y = -AJAR_GAP * 0.5
	shape.size = size
	cs.position = offset
	_door_corners[i] = Geom2D.rect_corners(Rect2(r.get_center() + offset - size * 0.5, size))


func _add_corner_angles(angles: Array[float], corners: PackedVector2Array, origin: Vector2, radius: float) -> void:
	var r2 := radius * radius
	for c in corners:
		var d := c - origin
		if d.length_squared() > r2:
			continue
		var a := d.angle()
		angles.append(a - RAY_EPS)
		angles.append(a)
		angles.append(a + RAY_EPS)


func _cast(origin: Vector2, angles: Array[float], radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for a in angles:
		var to := origin + Vector2.from_angle(a) * radius
		var hit := ray_hit(origin, to)
		pts.append(hit["position"] if not hit.is_empty() else to)
	return pts


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
