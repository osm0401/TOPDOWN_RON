class_name WorldView3D
extends Node3D
## PLACEHOLDER angled 3D rendering of NetWorld: primitive shapes; characters use the models in
## assets/characters/ when they exist (CharacterModels), the primitive figures otherwise.
## The simulation stays in 2D plane coordinates, (x, y) px -> (x, 0, y) / px_per_m.
## WorldView keeps computing the sight polygon, flashlight cones and per-NPC visibility;
## this node reads that cache (view._vis, _cones, ...) and only draws. HUD, briefing and
## result screen stay 2D canvas layers.

const FOG := Color(0.02, 0.02, 0.03)
const FAR := 5000.0
const BEAM_Y := 1.2
const LYING_Y := 0.28
const SURFACE := preload("res://src/game/surface.gdshader")
const CharacterModels := preload("res://src/game/character_models.gd")

var world: NetWorld
var view: WorldView

var _cfg: Dictionary = {}
var _k := 0.02  ## meters per px
var _wall_h := 1.6
var _actor_h := 1.7
var _body_h := 1.4
var _cam: Camera3D
var _cam_pos := Vector2.ZERO
var _cam_off := Vector2.ZERO  ## eased mouse look-ahead; the camera itself rides rigidly on the player
var _cam_blend := 0.0  ## 0 follow the player, 1 door camera
var _fog := ArrayMesh.new()
var _fog_poly := PackedVector2Array()  ## the sight polygon and origin the fog mesh was built from
var _fog_origin := Vector2.INF
var _ring := TorusMesh.new()
var _cam_ring: MeshInstance3D
var _sil_ring: MeshInstance3D  ## outline range around the local officer in a dark room
var _walls: Array[MeshInstance3D] = []
var _wall_cut: Array[float] = []  ## per-wall height factor, lowered while it hides the local player
var _doors: Array[Dictionary] = []
var _players: Array[Dictionary] = []
var _npcs: Array[Dictionary] = []
var _fx: Array[Dictionary] = []  ## live ripples, tracers, muzzle flashes and speech bubbles
var _lights: Array[Dictionary] = []  ## static ceiling/street lights: {node, pos (px)}


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/view3d.json")
	_k = 1.0 / float(_cfg["px_per_m"])
	_wall_h = float(_cfg["wall_h"])
	_actor_h = float(_cfg["actor_h"])
	_body_h = _actor_h - 0.3
	_ring.inner_radius = 0.94
	_ring.outer_radius = 1.0
	_ring.rings = 32
	_ring.ring_segments = 4
	_cam_pos = world.display_pos(world.my_slot)
	_build_environment()
	_build_level()
	for s in 2:
		_players.append(_make_player(s))
	for a in world.director.agents:
		_npcs.append(_make_npc(a))
	world.mouse_world = _mouse_ground
	world.sound_emitted.connect(_on_sound)
	world.shot_fired.connect(_on_shot)
	world.speech_emitted.connect(_on_speech)


func _exit_tree() -> void:
	if is_instance_valid(world) and world.mouse_world == _mouse_ground:
		world.mouse_world = Callable()


# ---- helpers ----------------------------------------------------------------

func _p3(p: Vector2, y := 0.0) -> Vector3:
	return Vector3(p.x * _k, y, p.y * _k)


func _mat(c: Color, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _add(mesh: Mesh, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	var bm := mat as BaseMaterial3D
	if bm != null and (bm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED or bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # overlays, beams, fog never shade
	(parent if parent != null else self).add_child(mi)
	return mi


func _col(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


## Procedural PBR surface from data/view3d.json "surfaces" (ground, floor, wall, door).
func _surface_mat(key: String) -> ShaderMaterial:
	var s: Dictionary = _cfg["surfaces"][key]
	var m := ShaderMaterial.new()
	m.shader = SURFACE
	m.set_shader_parameter("mode", int(s["mode"]))
	for k in ["color_a", "color_b", "grout"]:
		if s.has(k):
			m.set_shader_parameter(k, _col(s[k]))
	for k in ["scale", "tile_m", "rough_min", "rough_max", "bump", "grime_m"]:
		if s.has(k):
			m.set_shader_parameter(k, float(s[k]))
	return m


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	return s


func _capsule() -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = NetWorld.PLAYER_RADIUS * _k
	c.height = _body_h
	return c


func _label(pixel: float, color := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = pixel
	l.font_size = 48
	l.outline_size = 12
	l.modulate = color
	return l


func _floor(r: Rect2, y: float, mat: Material) -> MeshInstance3D:
	var pm := PlaneMesh.new()
	pm.size = r.size * _k
	var mi := _add(pm, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = _p3(r.get_center(), y)
	return mi


## Thin box from a to b (tracers, laser).
func _beam(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var len := a.distance_to(b)
	mi.visible = len > 0.01
	if not mi.visible:
		return
	mi.position = (a + b) * 0.5
	mi.look_at(b)
	mi.scale = Vector3(1.0, 1.0, len)


func _surface(mesh: ArrayMesh, pts: PackedVector3Array, idx: PackedInt32Array) -> void:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


func _fan(mesh: ArrayMesh, poly: PackedVector2Array, y: float) -> void:
	mesh.clear_surfaces()
	var n := poly.size()
	if n < 3:
		return
	var pts := PackedVector3Array()
	var idx := PackedInt32Array()
	for p in poly:
		pts.append(_p3(p, y))
	for i in range(1, n - 1):
		idx.append_array(PackedInt32Array([0, i, i + 1]))
	_surface(mesh, pts, idx)


## True when the sight polygon touches the rect (what is outside it stays fogged).
func _in_sight(r: Rect2) -> bool:
	var v := view._vis
	if v.size() < 3:
		return true
	var g := r.grow(2.0)
	var poly := PackedVector2Array([g.position, Vector2(g.end.x, g.position.y), g.end, Vector2(g.position.x, g.end.y)])
	return not Geometry2D.intersect_polygons(v, poly).is_empty()


# ---- build ------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = FOG
	var lc: Dictionary = _cfg["lighting"]
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _col(lc["ambient"]["color"])
	env.ambient_light_energy = float(lc["ambient"]["energy"])
	# Forward+ look: contact shadows, bloom around lights, haze that shows beams, filmic grade
	env.ssao_enabled = true
	env.ssao_intensity = 2.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = float(lc["haze_density"])
	env.volumetric_fog_albedo = Color(0.7, 0.75, 0.85)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.1
	env.adjustment_saturation = 0.85
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	_cam = Camera3D.new()
	_cam.fov = float(_cfg["camera"]["fov_deg"])
	_cam.far = 300.0
	add_child(_cam)
	_cam.make_current()
	_cam_ring = _add(_ring, _mat(Color(0.6, 1.0, 0.6), true))
	_cam_ring.scale = Vector3(14.0 * _k, 1.0, 14.0 * _k)
	_cam_ring.visible = false


func _build_level() -> void:
	var lv := world.level
	_floor(lv.bounds, 0.0, _surface_mat("ground"))
	_floor(lv.building, 0.005, _surface_mat("floor"))
	for rm in lv.rooms:
		if rm["dark"]:  # darkness itself comes from the missing ceiling light
			var sign_label := _label(0.02, Color(0.75, 0.82, 1.0, 0.45))  # flat on the floor, under the fog
			sign_label.text = tr("어두운 방")
			sign_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
			sign_label.rotation_degrees.x = -90.0
			sign_label.position = _p3((rm["rect"] as Rect2).get_center(), 0.02)
			add_child(sign_label)
	_sil_ring = _add(_ring, _mat(Color(0.7, 0.8, 1.0, 0.5), true))
	_sil_ring.scale = Vector3.ONE * (float(world.tuning["light"]["silhouette_radius"]) * _k)
	_sil_ring.visible = false
	_floor(lv.exit_zone, 0.015, _mat(Color(0.1, 0.5, 0.2, 0.5), true))
	var wall_mat := _surface_mat("wall")
	var caster_h := float(_cfg["lighting"]["shadow_caster_h"])
	for r in lv.wall_rects:
		var mi := _add(_box(Vector3(r.size.x * _k, _wall_h, r.size.y * _k)), wall_mat)
		mi.position = _p3(r.get_center(), _wall_h * 0.5)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # the full-height caster below shades
		_walls.append(mi)
		_wall_cut.append(1.0)
		var sh := _add(_box(Vector3(r.size.x * _k, caster_h, r.size.y * _k)), wall_mat)
		sh.position = _p3(r.get_center(), caster_h * 0.5)
		sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY  # light must not pass over low walls
	for i in lv.door_rects.size():
		var leaf_mat := _surface_mat("door")
		var mark_mat := _mat(Color(1, 1, 1, 0.0), true)
		var leaf := _add(_box(Vector3.ONE), leaf_mat)
		leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var shade := _add(_box(Vector3.ONE), leaf_mat)
		shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		_doors.append({
			"leaf": leaf, "leaf_mat": leaf_mat, "cut": 1.0, "shade": shade, "shade_rect": Rect2(),
			"mark": _floor(lv.door_rects[i], 0.02, mark_mat), "mark_mat": mark_mat,
			"lock": _add(_sphere(0.12), _mat(Color(0.9, 0.1, 0.1), true))})
	_build_lights()
	_add(_fog, _mat(FOG, true))


## Ceiling lights in lit rooms only (long rooms get one per spacing_m), a street lamp at
## the exit. Dark rooms get none, so light spills in only through open doors.
func _build_lights() -> void:
	var lc: Dictionary = _cfg["lighting"]
	var rc: Dictionary = lc["room"]
	for rm in world.level.rooms:
		if rm["dark"]:
			continue
		var r: Rect2 = rm["rect"]
		var along_x := r.size.x >= r.size.y
		var n := maxi(1, roundi((r.size.x if along_x else r.size.y) * _k / float(rc["spacing_m"])))
		for i in n:
			var t := (float(i) + 0.5) / float(n)
			_add_omni(r.position + (Vector2(r.size.x * t, r.size.y * 0.5) if along_x else Vector2(r.size.x * 0.5, r.size.y * t)),
					float(rc["height_m"]), float(rc["energy"]), float(rc["range_m"]), _col(rc["color"]))
	var sc: Dictionary = lc["street"]
	_add_omni(world.level.exit_zone.get_center(), float(sc["height_m"]), float(sc["energy"]), float(sc["range_m"]), _col(sc["color"]))


func _add_omni(at: Vector2, height: float, energy: float, range_m: float, color: Color) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_energy = energy
	l.omni_range = range_m
	l.light_color = color
	l.shadow_enabled = true
	l.position = _p3(at, height)
	add_child(l)
	_lights.append({"node": l, "pos": at})
	return l


func _make_player(slot: int) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var rig := Node3D.new()
	root.add_child(rig)
	var mat := _mat(WorldView.PLAYER_COLORS[slot])
	mat.emission_enabled = true
	var model := CharacterModels.make("officer", _cfg["characters"])
	if model.is_empty():
		_add(_capsule(), mat, rig).position.y = _body_h * 0.5
		_add(_sphere(0.17), mat, rig).position.y = _body_h + 0.12
	else:
		rig.add_child(model["node"])
	var gun := _add(_box(Vector3(0.6, 0.08, 0.08)), _mat(Color.WHITE), rig)
	gun.position = Vector3(0.45, 1.15, 0.0)
	var label := _label(0.006)
	label.position.y = _actor_h + 0.45
	root.add_child(label)
	var ring := _add(_ring, _mat(Color.WHITE, true), root)
	ring.position.y = 0.02
	ring.scale = Vector3(0.4, 1.0, 0.4)
	ring.visible = slot == world.my_slot
	var cone := ArrayMesh.new()  # exact sim beam area, kept faint beside the real light
	_add(cone, _mat(Color(1.0, 0.95, 0.6, 0.07), true))
	var fc: Dictionary = _cfg["lighting"]["flash"]
	var spot := SpotLight3D.new()
	spot.light_energy = float(fc["energy"])
	spot.light_color = _col(fc["color"])
	spot.light_volumetric_fog_energy = float(fc["fog_energy"])
	spot.spot_range = float(world.tuning["light"]["flash_range"]) * _k
	spot.spot_angle = float(world.tuning["light"]["flash_fov_deg"]) * 0.5
	spot.shadow_enabled = true
	spot.position = Vector3(0.3, float(fc["height_m"]), 0.0)
	spot.rotation_degrees = Vector3(float(fc["pitch_deg"]), -90.0, 0.0)  # -Z of the light -> rig +X (aim)
	spot.visible = false
	rig.add_child(spot)
	return {
		"root": root, "rig": rig, "mat": mat, "model": model, "gun": gun, "label": label, "cone": cone, "spot": spot,
		"beam": _add(_box(Vector3(0.02, 0.02, 1.0)), _mat(Color(1.0, 0.1, 0.1, 0.75), true)),
		"dot": _add(_sphere(0.05), _mat(Color(1.0, 0.2, 0.2), true))}


func _make_npc(a: NpcDirector.Agent) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var rig := Node3D.new()
	root.add_child(rig)
	var mat := _mat(WorldView.ENEMY_COLOR)
	var kind := "enemy" if a.brain.role == NpcBrain.Role.ENEMY else "civilian"
	var model := CharacterModels.make(kind, _cfg["characters"])
	var model_up := CharacterModels.make(kind + "_up", _cfg["characters"]) if not model.is_empty() else {}
	if model.is_empty():
		_add(_capsule(), mat, rig).position.y = _body_h * 0.5
		_add(_sphere(0.17), mat, rig).position.y = _body_h + 0.12
	else:
		rig.add_child(model["node"])
		if not model_up.is_empty():  # hands up (surrender) has its own model
			rig.add_child(model_up["node"])
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.19
	cap_mesh.bottom_radius = 0.19
	cap_mesh.height = 0.08
	var cap := _add(cap_mesh, _mat(Color(1.0, 0.1, 0.1)), rig)
	cap.position.y = _body_h + 0.3
	var band := _add(_box(Vector3(0.22, 0.14, 0.14)), _mat(Color(1.0, 0.9, 0.2)), rig)
	band.position = Vector3(0.0, 1.0, 0.3)
	var gun := _add(_box(Vector3(0.6, 0.08, 0.08)), _mat(Color.WHITE), rig)
	gun.position = Vector3(0.45, 1.15, 0.0)
	var arms := Node3D.new()
	rig.add_child(arms)
	for side in [-0.3, 0.3]:
		_add(_box(Vector3(0.07, 0.5, 0.07)), mat, arms).position = Vector3(0.0, 1.45, side)
	var cuffs := _add(_box(Vector3(0.1, 0.1, 0.4)), _mat(Color(1.0, 0.9, 0.2)), rig)
	cuffs.position = Vector3(0.2, 0.7, 0.0)
	var dropped := _add(_box(Vector3(0.5, 0.06, 0.1)), _mat(Color(1.0, 0.9, 0.3)), root)
	dropped.position = Vector3(0.3, 0.05, 0.35)
	var sil := _add(_capsule(), _mat(Color(0.35, 0.35, 0.4, 0.8), true), root)
	sil.position.y = _body_h * 0.5
	var marker := _label(0.012)
	marker.position.y = _actor_h + 0.6
	root.add_child(marker)
	var dbg := _label(0.005, Color(1, 1, 1, 0.85))
	dbg.position.y = 0.1
	root.add_child(dbg)
	return {"root": root, "rig": rig, "mat": mat, "model": model, "model_up": model_up, "cap": cap, "band": band, "gun": gun,
			"arms": arms, "cuffs": cuffs, "dropped": dropped, "sil": sil, "marker": marker, "dbg": dbg}


# ---- input ------------------------------------------------------------------

## Ground point (px) under a screen position, on the chest-height plane so the aim
## direction matches the cursor as seen from the drawn figure.
func ground_at(screen: Vector2) -> Vector2:
	var o := _cam.project_ray_origin(screen)
	var n := _cam.project_ray_normal(screen)
	if absf(n.y) < 0.001:
		return world.display_pos(world.my_slot)
	var p := o + n * ((float(_cfg["aim_height_m"]) - o.y) / n.y)
	return Vector2(p.x, p.z) / _k


func _mouse_ground() -> Vector2:
	return ground_at(get_viewport().get_mouse_position())


# ---- events -----------------------------------------------------------------

func _on_sound(kind: int, pos: Vector2) -> void:
	var m := _mat(WorldView.SOUND_COLORS[kind], true)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var tm := TorusMesh.new()  # own mesh: the ring keeps a constant width while it grows
	tm.rings = 48
	tm.ring_segments = 4
	_fx.append({"type": "ripple", "node": _add(tm, m), "mesh": tm, "mat": m, "age": 0.0, "kind": kind, "pos": pos})


func _on_shot(shooter: int, from: Vector2, to: Vector2, _hit_npc: bool) -> void:
	var m := _mat(Color(1.0, 0.35, 0.3) if shooter >= 2 else Color(1.0, 0.95, 0.5), true)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := _add(_box(Vector3(0.04, 0.04, 1.0)), m)
	_beam(mi, _p3(from, BEAM_Y), _p3(to, BEAM_Y))
	_fx.append({"type": "tracer", "node": mi, "mat": m, "age": 0.0})
	var mc: Dictionary = _cfg["lighting"]["muzzle"]  # the shot lights the room for a moment
	var flash := OmniLight3D.new()
	flash.light_energy = float(mc["energy"])
	flash.omni_range = float(mc["range_m"])
	flash.light_color = _col(mc["color"])
	flash.shadow_enabled = true
	flash.position = _p3(from, float(mc["height_m"]))
	add_child(flash)
	_fx.append({"type": "flash", "node": flash, "age": 0.0, "energy": float(mc["energy"]), "life": float(mc["life_s"])})


func _on_speech(text: String, pos: Vector2, from_npc: bool) -> void:
	var l := _label(0.006, Color(1, 1, 0.8))
	l.text = text
	l.no_depth_test = true
	add_child(l)
	_fx.append({"type": "bubble", "node": l, "age": 0.0, "pos": pos, "npc": from_npc})


# ---- per frame --------------------------------------------------------------

func _process(delta: float) -> void:
	_update_camera(delta)
	_update_fog()
	_update_level(delta)
	_update_players(delta)
	_update_npcs(delta)
	_update_fx(delta)


## Render-side smoothing: sim positions arrive in steps (60 Hz host physics, 20 Hz client
## snapshots), so remote figures ease toward them instead of jumping.
func _ease_pos(n: Dictionary, target: Vector2, delta: float) -> Vector2:
	var p: Vector2 = n.get("pos", target)
	if p.distance_to(target) > 120.0:
		p = target
	p = p.lerp(target, minf(delta * float(_cfg["ease_rate"]), 1.0))
	n["pos"] = p
	return p


func _ease_yaw(node: Node3D, target: float, delta: float) -> void:
	node.rotation.y = lerp_angle(node.rotation.y, target, minf(delta * float(_cfg["ease_rate"]) * 0.6, 1.0))


func _update_camera(delta: float) -> void:
	var me := world.players[world.my_slot]
	var step := minf(delta * 12.0, 1.0)
	var off := Vector2.ZERO
	if me.cam_door < 0 and world.auto_role == "":
		var vp := get_viewport()
		off = ((vp.get_mouse_position() - vp.get_visible_rect().size * 0.5) * 0.3).limit_length(160.0)
	_cam_off = _cam_off.lerp(off, step)
	_cam_blend = move_toward(_cam_blend, 1.0 if me.cam_door >= 0 else 0.0, delta * 6.0)
	var target := (world.display_pos(world.my_slot) + _cam_off).lerp(view._vis_origin, _cam_blend)
	_cam_pos = target
	var c: Dictionary = _cfg["camera"]
	var pitch := deg_to_rad(float(c["pitch_deg"]))
	var at := _p3(_cam_pos)
	_cam.position = at + Vector3(0.0, sin(pitch), cos(pitch)) * float(c["distance_m"])
	_cam.look_at(at)
	_cam_ring.visible = me.cam_door >= 0
	_cam_ring.position = _p3(view._vis_origin, 0.04)
	var here := world.display_pos(world.my_slot)
	_sil_ring.visible = me.present and view._outline_only(me, here)
	_sil_ring.position = _p3(here, 0.04)


## Fog = quads from every sight-polygon edge out to FAR, flat on the floor. Rebuilt only when the
## sight polygon changed (it changes at most once per physics frame, not at all while standing).
func _update_fog() -> void:
	var v := view._vis
	var o: Vector2 = view._vis_origin
	if v == _fog_poly and o == _fog_origin:
		return
	_fog_poly = v
	_fog_origin = o
	_fog.clear_surfaces()
	var n := v.size()
	if n < 3:
		return
	var y := float(_cfg["fog_y"])
	var pts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in n:
		var a := v[i]
		var b := v[(i + 1) % n]
		var q := pts.size()
		pts.append(_p3(a, y))
		pts.append(_p3(b, y))
		pts.append(_p3(o + (b - o).normalized() * FAR, y))
		pts.append(_p3(o + (a - o).normalized() * FAR, y))
		idx.append_array(PackedInt32Array([q, q + 1, q + 2, q, q + 2, q + 3]))
	_surface(_fog, pts, idx)


## Height factor for a wall: low while it stands between the camera (south) and the local
## player, because the camera always looks north.
func _cut_target(r: Rect2) -> float:
	var me := world.display_pos(world.my_slot)
	var cut: Dictionary = _cfg["cutaway"]
	return float(cut["low"]) if r.intersects(Rect2(me.x - 30.0, me.y, 60.0, float(cut["reach_px"]))) else 1.0


func _update_level(delta: float) -> void:
	var lv := world.level
	var step := minf(delta * 10.0, 1.0)
	for i in _walls.size():
		_wall_cut[i] = lerpf(_wall_cut[i], _cut_target(lv.wall_rects[i]), step)
		_walls[i].visible = _in_sight(lv.wall_rects[i])
		_walls[i].scale.y = _wall_cut[i]
		_walls[i].position.y = _wall_h * 0.5 * _wall_cut[i]
	for i in _doors.size():
		var d: Dictionary = _doors[i]
		var st := lv.get_door_state(i)
		var seen := _in_sight(lv.door_rects[i])
		var col := WorldView.DOOR_COLORS[lv.door_actor[i]]
		var leaf: MeshInstance3D = d["leaf"]
		leaf.visible = seen and st != Level.DoorState.OPEN
		if leaf.visible:
			var r := lv.door_collider_rect(i)
			d["cut"] = lerpf(d["cut"], _cut_target(r), step)
			var h: float = _wall_h * 0.9 * d["cut"]
			(leaf.mesh as BoxMesh).size = Vector3(r.size.x * _k, h, r.size.y * _k)
			leaf.position = _p3(r.get_center(), h * 0.5)
			# whoever touched the door last tints the wood (blue = host, orange = client)
			(d["leaf_mat"] as ShaderMaterial).set_shader_parameter("tint", Color.WHITE if lv.door_actor[i] == 0 else Color.WHITE.lerp(col, 0.6))
		var shade: MeshInstance3D = d["shade"]  # full-height shadow caster, independent of fog visibility
		var cr := lv.door_collider_rect(i)
		shade.visible = st != Level.DoorState.OPEN
		if shade.visible and cr != d["shade_rect"]:
			var caster_h := float(_cfg["lighting"]["shadow_caster_h"])
			d["shade_rect"] = cr
			(shade.mesh as BoxMesh).size = Vector3(cr.size.x * _k, caster_h, cr.size.y * _k)
			shade.position = _p3(cr.get_center(), caster_h * 0.5)
		(d["mark"] as MeshInstance3D).visible = seen
		(d["mark_mat"] as StandardMaterial3D).albedo_color = Color(col, 0.5 if st == Level.DoorState.OPEN else 0.0)
		var lock: MeshInstance3D = d["lock"]
		lock.visible = leaf.visible and lv.is_locked(i)
		lock.position = _p3(lv.door_rects[i].get_center(), _wall_h + 0.2)


func _update_players(delta: float) -> void:
	for s in 2:
		var ps := world.players[s]
		var n: Dictionary = _players[s]
		var root: Node3D = n["root"]
		root.visible = ps.present
		if not ps.present:
			continue
		var at := world.display_pos(s)
		var yaw := -ps.aim
		if s != world.my_slot:  # the local figure stays exact; the other officer is eased
			at = _ease_pos(n, at, delta)
			yaw = lerp_angle(n.get("yaw", yaw), yaw, minf(delta * float(_cfg["ease_rate"]) * 0.6, 1.0))
			n["yaw"] = yaw
		var dead := ps.dead()
		root.position = _p3(at)
		var rig: Node3D = n["rig"]
		var model: Dictionary = n["model"]
		rig.basis = Basis(Vector3.UP, yaw) * (Basis(Vector3.BACK, PI * 0.5) if dead else Basis.IDENTITY)
		rig.position.y = (float(model.get("lie_y", LYING_Y)) if dead else 0.0)
		var pm := n["mat"] as StandardMaterial3D
		pm.albedo_color = Color(0.5, 0.5, 0.5) if dead else WorldView.PLAYER_COLORS[s]
		pm.emission = pm.albedo_color * 0.3  # officers stay readable in a dark room
		if not model.is_empty():  # the two officers keep their colours (and stay readable in the dark) as a tint
			var tint: Color = Color(0.5, 0.5, 0.5, 0.55) if dead else WorldView.PLAYER_COLORS[s]
			if not dead:
				tint.a = float(_cfg["characters"]["player_tint"])
			(model["overlay"] as StandardMaterial3D).albedo_color = tint
		(n["gun"] as Node3D).visible = not dead
		(n["spot"] as Node3D).visible = ps.flash and not dead
		var text := "" if dead else "HP %d/%d" % [ps.hp, ps.max_hp]
		if ps.busy():
			text += "\n%s %d%%" % [WorldView.ACTION_LABELS[ps.action], int(100.0 * clampf(ps.action_t / ps.action_dur, 0.0, 1.0))]
		(n["label"] as Label3D).text = text
		_fan(n["cone"], view._cones[s], 0.02)
		var dot: Vector2 = view._laser_dots[s]
		var beam: MeshInstance3D = n["beam"]
		var dot_node: MeshInstance3D = n["dot"]
		dot_node.visible = dot != Vector2.INF
		if dot == Vector2.INF:
			beam.visible = false
		else:
			dot_node.position = _p3(dot, BEAM_Y)
			_beam(beam, _p3(at + Vector2.from_angle(ps.aim) * 18.0, BEAM_Y), dot_node.position)


func _update_npcs(delta: float) -> void:
	var S := NpcBrain.State
	var agents := world.director.agents
	for i in agents.size():
		var a: NpcDirector.Agent = agents[i]
		var n: Dictionary = _npcs[i]
		var root: Node3D = n["root"]
		var seen: int = view._npc_seen[i] if i < view._npc_seen.size() else LightModel.Seen.IDENTIFIED
		root.visible = not a.dormant and seen != LightModel.Seen.NONE
		if not root.visible:
			n.erase("pos")  # next appearance snaps to the sim position
			continue
		var sil := seen == LightModel.Seen.SILHOUETTE
		var fresh := not n.has("pos")
		root.position = _p3(_ease_pos(n, a.pos, delta))
		(n["sil"] as Node3D).visible = sil
		(n["rig"] as Node3D).visible = not sil
		(n["marker"] as Label3D).visible = not sil
		(n["dbg"] as Label3D).visible = not sil and view._debug
		if sil:
			(n["dropped"] as Node3D).visible = false
			continue
		var b := a.brain
		var st: int = b.state
		if fresh:
			root.rotation.y = -b.facing
		else:
			_ease_yaw(root, -b.facing, delta)  # the sim snaps facing at path corners; turn smoothly
		var base :=WorldView.ENEMY_COLOR if b.role == NpcBrain.Role.ENEMY else WorldView.CIVILIAN_COLOR
		var col := base
		match st:
			S.DEAD:
				col = Color(0.5, 0.5, 0.5)
			S.DOWN, S.HIDE:
				col = base.darkened(0.2)
			S.RESTRAINED:
				col = base.darkened(0.4)
		var flash := false
		for k in view._npc_flash:
			if (k as Vector2).distance_to(a.pos) < 24.0:
				flash = true
				col = Color.WHITE
		(n["mat"] as StandardMaterial3D).albedo_color = col
		var lying := st == S.DOWN or st == S.DEAD
		var rig: Node3D = n["rig"]
		var model: Dictionary = n["model"]
		var model_up: Dictionary = n["model_up"]
		var hands_up := st == S.SURRENDER and not model_up.is_empty()
		rig.basis = Basis(Vector3.BACK, PI * 0.5) if lying else Basis.IDENTITY
		rig.position.y = float(model.get("lie_y", LYING_Y)) if lying else 0.0
		if not model.is_empty():
			(model["node"] as Node3D).visible = not hands_up
			var tint := _npc_tint(st, flash)
			(model["overlay"] as StandardMaterial3D).albedo_color = tint
			if hands_up:
				(model_up["node"] as Node3D).visible = true
				(model_up["overlay"] as StandardMaterial3D).albedo_color = tint
			elif not model_up.is_empty():
				(model_up["node"] as Node3D).visible = false
		rig.scale = Vector3(1.0, 0.6 if st == S.HIDE else (0.65 if st == S.RESTRAINED else 1.0), 1.0)
		(n["cap"] as Node3D).visible = a.clues.has("cap")
		(n["band"] as Node3D).visible = a.clues.has("band")
		(n["gun"] as Node3D).visible = b.armed and st != S.DOWN and st != S.HIDE and st != S.DEAD
		(n["arms"] as Node3D).visible = st == S.SURRENDER and not hands_up
		(n["cuffs"] as Node3D).visible = st == S.RESTRAINED
		(n["dropped"] as Node3D).visible = b.had_weapon and not b.armed
		var marker := ""
		var marker_color := Color(1.0, 0.45, 0.1)
		match st:
			S.SPOTTED:
				marker = "?"
				marker_color = Color.YELLOW
			S.THREAT:
				marker = "!"
			S.ATTACK:
				marker = "!!"
			S.DOWN:  # alive: a stunned enemy gets up again
				marker = tr("엎드림")
				marker_color = Color(0.6, 0.8, 1.0)
			S.SURRENDER:
				marker = tr("항복")
				marker_color = Color.WHITE
			S.RESTRAINED:
				marker = tr("구속")
				marker_color = Color(0.5, 1.0, 0.5)
			S.DEAD:
				marker = tr("사망")
				marker_color = Color(0.75, 0.75, 0.75)
		(n["marker"] as Label3D).text = marker
		(n["marker"] as Label3D).modulate = marker_color
		(n["marker"] as Label3D).pixel_size = 0.012 if marker in ["?", "!", "!!"] else 0.007  # symbols big, words smaller
		var text: String = NpcBrain.STATE_NAMES[st]
		if b.feigning:
			text += " (가장)"
		if b.reason != "":
			text += ": " + b.reason
		(n["dbg"] as Label3D).text = text


## Tint laid over an NPC model: white flash when hit, grey when dead, darker while down, hiding
## or restrained (what the primitive figure shows with its colour).
func _npc_tint(st: int, flash: bool) -> Color:
	var S := NpcBrain.State
	if flash:
		return Color(1, 1, 1, 0.75)
	match st:
		S.DEAD:
			return Color(0.45, 0.45, 0.45, 0.6)
		S.DOWN, S.HIDE:
			return Color(0, 0, 0, 0.2)
		S.RESTRAINED:
			return Color(0, 0, 0, 0.35)
	return Color(0, 0, 0, 0)


func _update_fx(delta: float) -> void:
	var radii: Dictionary = world.tuning["sound_radius"]
	var keep: Array[Dictionary] = []
	for f in _fx:
		f["age"] += delta
		var node: Node3D = f["node"]
		var done := false
		match f["type"]:
			"ripple":
				var k: float = f["age"] / WorldView.RIPPLE_S
				var r := lerpf(8.0, float(radii[SoundProp.NAMES[f["kind"]]]), k) * _k
				(f["mesh"] as TorusMesh).outer_radius = r
				(f["mesh"] as TorusMesh).inner_radius = maxf(r - 0.06, 0.0)
				node.position = _p3(f["pos"], 0.06)
				node.visible = view._show_sound
				var c: Color = WorldView.SOUND_COLORS[f["kind"]]
				(f["mat"] as StandardMaterial3D).albedo_color = Color(c, 1.0 - k)
				done = k >= 1.0
			"flash":
				var k: float = f["age"] / f["life"]
				(node as OmniLight3D).light_energy = f["energy"] * (1.0 - k)
				done = k >= 1.0
			"tracer":
				var k: float = f["age"] / WorldView.TRACER_S
				(f["mat"] as StandardMaterial3D).albedo_color.a = 1.0 - k
				done = k >= 1.0
			"bubble":
				var life := WorldView.SPEECH_S
				var fade := 1.0 - clampf((float(f["age"]) - life * 0.7) / (life * 0.3), 0.0, 1.0)
				node.position = _p3(f["pos"], _actor_h + 0.9 + float(f["age"]) * 0.15)
				(node as Label3D).modulate.a = fade
				node.visible = not (f["npc"] and view._vis.size() >= 3 and not Geometry2D.is_point_in_polygon(f["pos"], view._vis))
				done = f["age"] >= life
		if done:
			node.queue_free()
		else:
			keep.append(f)
	_fx = keep
