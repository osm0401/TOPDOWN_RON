class_name WorldView3D
extends Node3D
## PLACEHOLDER angled 3D rendering of NetWorld: primitive shapes; characters use the models in
## assets/characters/ when they exist (CharacterModels, posed by CharacterAnim, carrying gear from
## GearModels; the model set in data/view3d.json characters.set comes first), the primitive figures
## otherwise. Mouse wheel: zoom.
## The simulation stays in 2D plane coordinates, (x, y) px -> (x, 0, y) / px_per_m.
## WorldView keeps computing the sight polygon, flashlight cones and per-NPC visibility;
## this node reads that cache (view._vis, _cones, ...) and only draws. HUD, briefing and
## result screen stay 2D canvas layers.

## A foot lands (walk cycle): at (px), speed (m/s), who (officer slot, or 2 + NPC index).
signal footstep(at: Vector2, speed: float, who: int)

const FOG := Color(0.02, 0.02, 0.03)
const FAR := 5000.0
const BEAM_Y := 1.2
const LYING_Y := 0.28
const SURFACE := preload("res://src/game/surface.gdshader")
const RIM_TINT := preload("res://src/game/rim_tint.gdshader")
const CharacterModels := preload("res://src/game/character_models.gd")
const CharacterAnim := preload("res://src/game/character_anim.gd")
const GearModels := preload("res://src/game/gear_models.gd")
const PropModels := preload("res://src/game/prop_models.gd")
const PeopleLooks := preload("res://src/game/people_looks.gd")

static var _zoom_to := 1.0  ## camera distance factor the mouse wheel asks for (kept across missions and F5)
static var tex_folder := "res://assets/textures/"  ## where surface pictures are looked for (tests point it elsewhere)
static var quality := ""  ## graphics level (data/view3d.json graphics.levels), F8 cycles; kept across missions and F5
const QUALITIES: Array[String] = ["high", "medium", "low"]

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
var _last_npc_shot := Vector2.INF  ## where the latest NPC shot came from (the officer it hit bleeds on that side)
var _walls: Array[MeshInstance3D] = []
var _wall_cut: Array[float] = []  ## per-wall height factor, lowered while it hides the local player
var _doors: Array[Dictionary] = []
var _players: Array[Dictionary] = []
var _npcs: Array[Dictionary] = []
var _fx: Array[Dictionary] = []  ## live ripples, tracers, muzzle flashes and speech bubbles
var _lights: Array[Dictionary] = []  ## static ceiling/street lights: {node, pos (px)}
var _props: Array[Dictionary] = []  ## furniture: {node, rect (px), tall, cut}
var _props_dirty := true  ## the sight polygon changed: furniture visibility to redo
var _police: Array[Dictionary] = []  ## police car light bars: {lights: [red, blue OmniLight3D], mats}
var _surf_cache: Dictionary = {}  ## surface key -> shared material
var _env: Environment
var _wear: Array[Decal] = []  ## grime, scuffs, cracks, papers, stains (static)
var _holes: Array[Decal] = []  ## bullet holes in walls and doors, oldest first (capped)
var _stains: Array[Decal] = []  ## blood on the floor, oldest first (capped)
var _casings: Array[Dictionary] = []  ## spent cases: {node, vel, spin, rest}, oldest first (capped)
var _casing_mesh: CylinderMesh
static var _tex: Dictionary = {}  ## generated effect textures: "hole", "blood", "puff"
var _zoom := 1.0  ## eased toward _zoom_to
var _t := 0.0  ## seconds since the view opened (breathing, idle sway)


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/view3d.json")
	GearModels.set_name = str(_cfg["characters"].get("set", ""))  # gear files of the same model set
	for arg in OS.get_cmdline_user_args():  # test aid for screenshots: -- --zoom=0.5
		if arg.begins_with("--zoom="):
			_zoom_to = clampf(float(arg.substr(7)), float(_cfg["camera"]["zoom_min"]), float(_cfg["camera"]["zoom_max"]))
			_zoom = _zoom_to
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
		_players[s]["who"] = s
	for i in world.director.agents.size():
		_npcs.append(_make_npc(world.director.agents[i], i))
		_npcs[i]["who"] = 2 + i
	world.mouse_world = _mouse_ground
	if quality == "":
		quality = str(_cfg["graphics"]["quality"])
	for arg in OS.get_cmdline_user_args():  # test aid: -- --quality=low
		if arg.begins_with("--quality="):
			quality = arg.substr(10)
	_apply_quality()
	world.sound_emitted.connect(_on_sound)
	world.shot_fired.connect(_on_shot)
	world.speech_emitted.connect(_on_speech)
	world.damaged.connect(_on_damaged)


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
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED  # nor bounce light
	(parent if parent != null else self).add_child(mi)
	return mi


func _col(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


## Procedural PBR surface from data/view3d.json "surfaces" (ground, floor, wall, door and the
## per-room / outdoor styles), one shared material per key.
func _surface_mat(key: String) -> ShaderMaterial:
	if _surf_cache.has(key):
		return _surf_cache[key]
	var s: Dictionary = _cfg["surfaces"][key]
	var m := ShaderMaterial.new()
	_surf_cache[key] = m
	m.shader = SURFACE
	m.set_shader_parameter("mode", int(s["mode"]))
	for k in ["color_a", "color_b", "grout"]:
		if s.has(k):
			m.set_shader_parameter(k, _col(s[k]))
	for k in ["scale", "tile_m", "rough_min", "rough_max", "bump", "grime_m", "plank_len", "dirt", "speckle", "bevel", "tex_m"]:
		if s.has(k):
			m.set_shader_parameter(k, float(s[k]))
	var tex := _surface_tex(key)
	if tex != null:
		m.set_shader_parameter("use_tex", true)
		m.set_shader_parameter("tex_albedo", tex)
	return m


## A picture of surface `key` from the model set (assets/textures/<set>/<key>.png, or .jpg), read
## without the editor's import when there is none; null when the set has none.
func _surface_tex(key: String) -> Texture2D:
	var set_name := str(_cfg["characters"].get("set", ""))
	if set_name == "":
		return null
	for ext in ["png", "jpg"]:
		var path := "%s%s/%s.%s" % [tex_folder, set_name, key, ext]
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(path))
			if img != null and not img.is_empty():
				img.generate_mipmaps()
				return ImageTexture.create_from_image(img)
	return null


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


## Moving geometry under `node` takes bounced light but is left out of the scene the bounce is
## computed from (people, gear, door leaves).
func _dynamic(node: Node) -> void:
	if node is GeometryInstance3D and (node as GeometryInstance3D).gi_mode == GeometryInstance3D.GI_MODE_STATIC:
		(node as GeometryInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	for c in node.get_children():
		_dynamic(c)


func _label(pixel: float, color := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
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
	_env = env
	env.background_mode = Environment.BG_COLOR
	env.background_color = FOG
	var lc: Dictionary = _cfg["lighting"]
	var gc: Dictionary = _cfg["graphics"]
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _col(lc["ambient"]["color"])
	# Forward+ look: contact shadows, bloom around lights, haze that shows beams, a photographic
	# grade (AgX); the quality level adds light bouncing off walls and floors, floor reflections
	# and soft shadows (_apply_quality)
	env.ssao_enabled = true
	env.ssao_radius = 0.8
	env.ssao_intensity = 2.2
	env.ssao_light_affect = 0.15  # corners darken a little even under direct light
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.volumetric_fog_density = float(lc["haze_density"])
	env.volumetric_fog_albedo = Color(0.7, 0.75, 0.85)
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = float(gc["exposure"])
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 0.92
	env.ssr_max_steps = 48
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.4
	env.sdfgi_use_occlusion = true
	env.sdfgi_read_sky_light = false
	env.sdfgi_min_cell_size = 0.15
	env.sdfgi_cascades = 3
	env.sdfgi_bounce_feedback = 0.4
	env.sdfgi_energy = float(gc["gi_energy"])
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.2
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var vignette := CanvasLayer.new()  # darker corners under the HUD (the HUD's layers draw on top)
	vignette.layer = -1
	var vr := ColorRect.new()
	vr.set_anchors_preset(Control.PRESET_FULL_RECT)
	vr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vm := ShaderMaterial.new()
	vm.shader = Shader.new()
	vm.shader.code = "shader_type canvas_item;\nuniform float strength = 0.35;\nvoid fragment() {\n\tfloat d = length((UV - 0.5) * vec2(1.6, 1.2));\n\tCOLOR = vec4(0.0, 0.0, 0.0, smoothstep(0.55, 1.15, d) * strength);\n}\n"
	vm.set_shader_parameter("strength", float(gc["vignette"]))
	vr.material = vm
	vignette.add_child(vr)
	add_child(vignette)
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
	if lv.ground.is_empty():
		_floor(lv.bounds, 0.0, _surface_mat("ground"))
	for i in lv.ground.size():  # outdoor surfaces in order, each a hair above the last; kerbs raised
		var g: Dictionary = lv.ground[i]
		var key := "ground_" + str(g["surface"])
		var gm := _surface_mat(key if _cfg["surfaces"].has(key) else "ground")
		var r: Rect2 = g["rect"]
		if float(g["h"]) > 0.0:
			var kerb := _add(_box(Vector3(r.size.x * _k, float(g["h"]), r.size.y * _k)), gm)
			kerb.position = _p3(r.get_center(), float(g["h"]) * 0.5)
		else:
			_floor(r, 0.001 + 0.002 * i, gm)
	_floor(lv.building, 0.018, _surface_mat("floor"))
	for rm in lv.rooms:
		var fk := "floor_" + str(rm["floor"])
		_floor(rm["rect"], 0.02, _surface_mat(fk if _cfg["surfaces"].has(fk) else "floor"))
		if rm["dark"]:  # darkness itself comes from the missing ceiling light
			var sign_label := _label(0.02, Color(0.75, 0.82, 1.0, 0.45))  # flat on the floor, under the fog
			sign_label.text = tr("어두운 방")
			sign_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
			sign_label.rotation_degrees.x = -90.0
			sign_label.position = _p3((rm["rect"] as Rect2).get_center(), 0.025)
			add_child(sign_label)
	_sil_ring = _add(_ring, _mat(Color(0.7, 0.8, 1.0, 0.5), true))
	_sil_ring.scale = Vector3.ONE * (float(world.tuning["light"]["silhouette_radius"]) * _k)
	_sil_ring.visible = false
	_floor(lv.exit_zone, 0.015, _mat(Color(0.1, 0.5, 0.2, 0.18), true))  # the way out: a faint wash inside a painted border
	var ez := lv.exit_zone
	var line := _mat(Color(0.25, 0.85, 0.4), true)
	for e: Rect2 in [Rect2(ez.position, Vector2(ez.size.x, 3)), Rect2(ez.position + Vector2(0, ez.size.y - 3), Vector2(ez.size.x, 3)),
			Rect2(ez.position, Vector2(3, ez.size.y)), Rect2(ez.position + Vector2(ez.size.x - 3, 0), Vector2(3, ez.size.y))]:
		_floor(e, 0.016, line)
	var caster_h := float(_cfg["lighting"]["shadow_caster_h"])
	for r in lv.wall_rects:
		var mi := _wall(r)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # the full-height caster below shades
		_walls.append(mi)
		_wall_cut.append(1.0)
		var sh := _add(_box(Vector3(r.size.x * _k, caster_h, r.size.y * _k)), _surface_mat("wall"))
		sh.position = _p3(r.get_center(), caster_h * 0.5)
		sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY  # light must not pass over low walls
	for i in lv.door_rects.size():
		_doors.append(_make_door(i))
	_build_props()
	_build_wear()
	_build_lights()
	_add(_fog, _mat(FOG, true))


# ---- walls ------------------------------------------------------------------

## Collects primitive meshes per material for one merged mesh ({material: SurfaceTool}).
func _part(parts: Dictionary, mesh: PrimitiveMesh, mat: Material, xf: Transform3D) -> void:
	if not parts.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		parts[mat] = st
	(parts[mat] as SurfaceTool).append_from(mesh, 0, xf)


func _part_box(parts: Dictionary, size: Vector3, mat: Material, at: Vector3) -> void:
	_part(parts, _box(size), mat, Transform3D(Basis.IDENTITY, at))


func _merge(parts: Dictionary) -> ArrayMesh:
	var out := ArrayMesh.new()
	for mat: Material in parts:
		(parts[mat] as SurfaceTool).commit(out)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	return out


## What covers a wall face whose outside is at p: the room's paint, "wall" inside the building
## between rooms, brick outside. {mat, outside, room (index or -1)}.
func _face_style(p: Vector2) -> Dictionary:
	var lv := world.level
	if not lv.building.has_point(p):
		return {"mat": _surface_mat("wall_brick" if _cfg["surfaces"].has("wall_brick") else "wall"), "outside": true, "room": -1}
	var key := "wall_" + lv.room_style(p, "wall")
	return {"mat": _surface_mat(key if _cfg["surfaces"].has(key) else "wall"), "outside": false, "room": lv.room_at(p)}


## One wall: a dark-capped core with each face painted after the room it faces (split where the
## rooms change along it), skirting boards inside, a plinth outside, and windows where an outer
## wall closes a room (not the corridor). Origin at the wall's foot, so the cutaway scales it down.
func _wall(r: Rect2) -> MeshInstance3D:
	var lv := world.level
	var parts := {}
	var h := _wall_h
	var size := Vector3(r.size.x * _k, h, r.size.y * _k)
	var c := r.get_center()
	_part_box(parts, size, PropModels.mat("cap"), Vector3(0, h * 0.5, 0))
	var skirt := PropModels.mat("trim")
	var plinth := _surface_mat("ground_curb" if _cfg["surfaces"].has("ground_curb") else "wall")
	for axis in 2:  # 0: the faces looking -y / +y (along x), 1: the faces looking -x / +x (along y)
		var along := 0 if axis == 0 else 1
		var across := 1 - along
		var cuts: Array[float] = [r.position[along], r.end[along]]
		for rm in lv.rooms:
			var rr: Rect2 = rm["rect"]
			for e: float in [rr.position[along], rr.end[along]]:
				if e > r.position[along] + 0.5 and e < r.end[along] - 0.5:
					cuts.append(e)
		for e: float in [lv.building.position[along], lv.building.end[along]]:
			if e > r.position[along] + 0.5 and e < r.end[along] - 0.5:
				cuts.append(e)
		cuts.sort()
		for side: float in [-1.0, 1.0]:
			var face := (r.position[across] if side < 0.0 else r.end[across])
			for k in cuts.size() - 1:
				var a := cuts[k]
				var b := cuts[k + 1]
				if b - a < 0.5:
					continue
				var mid := (a + b) * 0.5
				var probe := Vector2.ZERO
				probe[along] = mid
				probe[across] = face + side * 6.0
				var st := _face_style(probe)
				var len_m := (b - a) * _k
				var at := Vector3.ZERO  # face centre relative to the wall centre (meters, 3D)
				var off := (face - c[across]) * _k + side * 0.002
				var seg_size: Vector3
				var normal := Vector3.ZERO
				if axis == 0:
					at = Vector3((mid - c.x) * _k, 0, off)
					seg_size = Vector3(len_m, 0, 0.004)
					normal = Vector3(0, 0, side)
				else:
					at = Vector3(off, 0, (mid - c.y) * _k)
					seg_size = Vector3(0.004, 0, len_m)
					normal = Vector3(side, 0, 0)
				_part_box(parts, Vector3(seg_size.x, h, seg_size.z), st["mat"], at + Vector3(0, h * 0.5, 0))
				var band := Vector3(maxf(seg_size.x, 0.02), 0, maxf(seg_size.z, 0.02))
				if st["outside"]:
					_part_box(parts, Vector3(band.x, 0.28, band.z), plinth, at + normal * 0.008 + Vector3(0, 0.14, 0))
				else:
					_part_box(parts, Vector3(band.x * (1.0 if axis == 0 else 0.0) + (0.016 if axis == 1 else 0.0), 0.1,
							band.z * (1.0 if axis == 1 else 0.0) + (0.016 if axis == 0 else 0.0)), skirt, at + normal * 0.008 + Vector3(0, 0.05, 0))
				# windows: an outer wall in front of a room (not the corridor)
				var inner := probe
				inner[across] = face - side * (r.size[across] + 6.0)
				var ri := lv.room_at(inner)
				if st["outside"] and ri >= 0 and str(lv.rooms[ri]["wall"]) != "corridor" and len_m >= 2.4:
					var n := int(len_m / 3.0) + 1
					for wi in n:
						var t := (wi + 0.5) / n
						var wc := Vector2.ZERO
						wc[along] = lerpf(a, b, t)
						wc[across] = c[across]
						_window(parts, Vector3((wc.x - c.x) * _k, 0, (wc.y - c.y) * _k), axis, r.size[across] * _k, not bool(lv.rooms[ri]["dark"]), side)
	var mi := MeshInstance3D.new()
	mi.mesh = _merge(parts)
	mi.position = _p3(c)
	add_child(mi)
	return mi


## A window through a wall `depth` thick at `at` (wall-local, on the centre line): glass and white
## frames on both faces, a sill, and a glass strip in the dark cap seen from above. From outside
## (the face on `outside`, -1 / 1) a lit room's window glows; from inside the glass shows the night.
func _window(parts: Dictionary, at: Vector3, axis: int, depth: float, lit: bool, outside: float) -> void:
	var trim := PropModels.mat("trim")
	var ww := 1.1
	var y0 := 0.72
	var y1 := 1.42
	var wh := y1 - y0
	var along := Vector3(1, 0, 0) if axis == 0 else Vector3(0, 0, 1)
	var out := Vector3(0, 0, 1) if axis == 0 else Vector3(1, 0, 0)
	var sz := func(l: float, hh: float, th: float) -> Vector3: return along * l + Vector3(0, hh, 0) + out * th
	for side: float in [-1.0, 1.0]:
		var face := at + out * side * (depth * 0.5 + 0.004)
		_part_box(parts, sz.call(ww - 0.06, wh - 0.06, 0.012), _window_glass(lit and side == outside), face + Vector3(0, (y0 + y1) * 0.5, 0))
		for e: float in [-1.0, 1.0]:
			_part_box(parts, sz.call(0.05, wh, 0.04), trim, face + along * e * (ww * 0.5) + Vector3(0, (y0 + y1) * 0.5, 0))
		_part_box(parts, sz.call(ww + 0.05, 0.05, 0.04), trim, face + Vector3(0, y1, 0))
		_part_box(parts, sz.call(0.03, wh, 0.03), trim, face + Vector3(0, (y0 + y1) * 0.5, 0))  # mullion
		_part_box(parts, sz.call(ww + 0.12, 0.04, 0.1), trim, face + out * side * 0.03 + Vector3(0, y0 - 0.02, 0))  # sill
	_part_box(parts, along * ww + Vector3(0, 0.006, 0) + out * depth * 0.3, _window_glass(false), at + Vector3(0, _wall_h + 0.003, 0))  # seen from above


func _window_glass(lit: bool) -> StandardMaterial3D:
	var key := "window_lit" if lit else "window_dark"
	if _surf_cache.has(key):
		return _surf_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.32, 0.4, 0.48) if lit else Color(0.06, 0.08, 0.11)
	m.roughness = 0.05
	m.metallic = 0.4
	if lit:
		m.emission_enabled = true
		m.emission = Color(1.0, 0.8, 0.55)
		m.emission_energy_multiplier = 0.35
	_surf_cache[key] = m
	return m


# ---- doors ------------------------------------------------------------------

## A door: the frame round the opening (casings, the wall piece over it, threshold), the leaf on a
## pivot at its hinge end (the low end of the opening) and the swing it makes. Open, the leaf
## turns 180 degrees to lie flat on the wall beside the opening, on whichever side has the room for
## it (the room side first; 90 degrees if neither has); ajar it turns just enough to leave the
## slit the rules leave at the far end.
func _make_door(i: int) -> Dictionary:
	var lv := world.level
	var r := lv.door_rects[i]
	var horiz := r.size.x >= r.size.y
	var along := 0 if horiz else 1
	var across := 1 - along
	var w := r.size[along] * _k
	var depth := r.size[across] * _k
	var leaf_h := _wall_h * 0.9
	var t := 0.05
	var root := Node3D.new()
	root.position = _p3(r.get_center())
	root.rotation.y = 0.0 if horiz else -PI * 0.5  # the opening runs along local X
	add_child(root)
	var frame := PropModels.door_frame(w, depth, _wall_h, leaf_h)
	root.add_child(frame)
	# which side to swing to: the side facing a room first, then the other; flat on the wall if free
	var c := r.get_center()
	var sides: Array[float] = [1.0, -1.0]
	var probe := c
	probe[across] += r.size[across] * 0.5 + 8.0
	var room_plus := lv.room_at(probe)
	if room_plus < 0 or str(lv.rooms[room_plus]["wall"]) == "corridor":
		sides = [-1.0, 1.0]
	var swing := sides[0]
	var open_deg := 90.0
	for s: float in sides:
		var zone := Rect2()  # where the opened leaf would lie (px), next to the hinge end, beyond the wall face
		var lo := Vector2.ZERO
		lo[along] = r.position[along] - r.size[along]
		lo[across] = (r.end[across] if s > 0.0 else r.position[across] - 6.0)
		var sz := Vector2.ZERO
		sz[along] = r.size[along] - 1.0
		sz[across] = 6.0
		zone = Rect2(lo, sz)
		var free := lv.bounds.encloses(zone)
		for wr in lv.wall_rects:
			free = free and not wr.intersects(zone)
		for pr in lv.props:
			free = free and not (pr["rect"] as Rect2).intersects(zone)
		if free:
			swing = s
			open_deg = 180.0
			break
	var zs := swing if horiz else -swing  # the swing side in the root's frame (a vertical door's local Z is world -X)
	var pivot := Node3D.new()
	pivot.position = Vector3(-w * 0.5, 0, zs * depth * 0.5)  # the hinge sits on the face the leaf swings to
	root.add_child(pivot)
	var leaf := PropModels.door_leaf(w, leaf_h, t)
	leaf.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC  # it swings
	leaf.position = Vector3(0, 0, -zs * t * 0.5)  # closed inside the opening; turned 180 degrees, flat on the wall
	pivot.add_child(leaf)
	var wood := (PropModels.mat("door_wood") as ShaderMaterial).duplicate() as ShaderMaterial
	leaf.set_surface_override_material(int(leaf.get_meta("wood")), wood)
	var shade := _add(_box(Vector3.ONE), _surface_mat("wall"))
	shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var mark_mat := _mat(Color(1, 1, 1, 0.0), true)
	var lock := PropModels.make("padlock", 0.12, 0.05)
	add_child(lock)
	var gap := float(Level.AJAR_GAP) / r.size[along]
	return {"root": root, "frame": frame, "pivot": pivot, "leaf": leaf, "leaf_mat": wood, "cut": 1.0, "shade": shade,
			"shade_rect": Rect2(), "mark": _floor(r, 0.024, mark_mat), "mark_mat": mark_mat, "lock": lock,
			"swing": swing, "zs": zs, "open_deg": open_deg, "ajar_deg": rad_to_deg(asin(clampf(gap, 0.0, 1.0))), "angle": 0.0}


# ---- furniture ----------------------------------------------------------------

## The map's furniture (PropModels, or model files of the model set), each turned to face where
## its front looks. Lamps and screens stay off in dark rooms. The police car's light bar gets two
## lights that flash.
func _build_props() -> void:
	PropModels.set_name = str(_cfg["characters"].get("set", ""))
	var lv := world.level
	var turn := {"s": 0.0, "e": PI * 0.5, "n": PI, "w": -PI * 0.5}
	for pr in lv.props:
		var r: Rect2 = pr["rect"]
		var face: String = pr["face"]
		var sideways := face == "e" or face == "w"
		var w := (r.size.y if sideways else r.size.x) * _k
		var d := (r.size.x if sideways else r.size.y) * _k
		var kind: String = pr["kind"]
		var mi := PropModels.make(kind, w, d, not lv.is_dark(r.get_center()))
		mi.position = _p3(r.get_center())
		mi.rotation.y = float(turn.get(face, 0.0))
		add_child(mi)
		var on_wall := -1  # a picture or board hangs on the wall it touches and drops with it
		if kind == "picture" or kind == "whiteboard":
			for wi in lv.wall_rects.size():
				if lv.wall_rects[wi].grow(2.0).intersects(r):
					on_wall = wi
					break
		_props.append({"node": mi, "rect": r, "tall": PropModels.is_tall(kind) and on_wall < 0, "cut": 1.0, "kind": kind, "wall": on_wall})
		if mi.has_meta("lights"):
			var pc: Dictionary = _cfg["lighting"]["police"]
			var lights: Array[OmniLight3D] = []
			var colors := [_col(pc["red"]), _col(pc["blue"])]
			for k in 2:
				var l := OmniLight3D.new()
				l.light_color = colors[k]
				l.omni_range = float(pc["range_m"])
				l.light_energy = 0.0
				l.shadow_enabled = false
				l.position = (mi.get_meta("lights") as Array)[k]
				mi.add_child(l)
				lights.append(l)
			_police.append({"lights": lights, "mats": mi.get_meta("light_mats")})


## Light bar pattern: red flashes twice, then blue twice, over period_s.
func _flash_police() -> void:
	if _police.is_empty():
		return
	var pc: Dictionary = _cfg["lighting"]["police"]
	var ph := fmod(_t, float(pc["period_s"])) / float(pc["period_s"])
	var on := [ph < 0.12 or (ph > 0.22 and ph < 0.34), (ph > 0.5 and ph < 0.62) or (ph > 0.72 and ph < 0.84)]
	for p in _police:
		for k in 2:
			(p["lights"][k] as OmniLight3D).light_energy = float(pc["energy"]) if on[k] else 0.0
			if k < (p["mats"] as Array).size():
				(p["mats"][k] as StandardMaterial3D).emission_energy_multiplier = 4.0 if on[k] else 0.2


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
	var lamps := 0
	for p in _props:  # street lamps hang their light from the lamp head (not from the pole: the cutaway lowers that)
		var node: Node3D = p["node"]
		if node.has_meta("lamp"):
			var head: Vector3 = node.transform * (node.get_meta("lamp") as Vector3)
			_add_omni(Vector2(head.x, head.z) / _k, head.y, float(sc["energy"]), float(sc["range_m"]), _col(sc["color"]))
			lamps += 1
	if lamps == 0:
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


# ---- graphics quality -------------------------------------------------------------

## Switches to the next graphics level (F8) and returns its name.
func cycle_quality() -> String:
	quality = QUALITIES[(QUALITIES.find(quality) + 1) % QUALITIES.size()]
	_apply_quality()
	return quality


## The level's effects (data/view3d.json graphics.levels): light bounced off walls and floors
## (SDFGI, or the cheaper screen-space SSIL), floor reflections (SSR), haze, edge smoothing (MSAA),
## soft shadow edges (light size) and the flat ambient light that stands in for bounce light.
func _apply_quality() -> void:
	var gc: Dictionary = _cfg["graphics"]
	if not (gc["levels"] as Dictionary).has(quality):
		quality = str(gc["quality"])
	var q: Dictionary = gc["levels"][quality]
	_env.sdfgi_enabled = bool(q["sdfgi"])
	_env.ssil_enabled = bool(q["ssil"])
	_env.ssr_enabled = bool(q["ssr"])
	_env.volumetric_fog_enabled = bool(q["fog"])
	_env.ambient_light_energy = float(_cfg["lighting"]["ambient"]["energy"]) * float(q["ambient"])
	get_viewport().msaa_3d = int(q["msaa"]) as Viewport.MSAA
	RenderingServer.positional_soft_shadow_filter_set_quality(int(q["shadow_filter"]) as RenderingServer.ShadowQuality)
	for l in _lights:
		(l["node"] as OmniLight3D).light_size = float(q["soft_shadow"])


func _make_player(slot: int) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var rig := Node3D.new()
	root.add_child(rig)
	var mat := _mat(WorldView.PLAYER_COLORS[slot])
	mat.emission_enabled = true
	var model := CharacterModels.make("officer", _cfg["characters"])
	if not model.is_empty():
		for mi in CharacterModels.meshes(model["node"]):
			mi.layers = 2  # people take no decals (bullet holes, blood on the floor)
		model["look"] = {"tints": {"patch": WorldView.PLAYER_COLORS[slot]}}  # shoulder patch in the player's colour
	var rim: ShaderMaterial = null
	if model.is_empty():
		_add(_capsule(), mat, rig).position.y = _body_h * 0.5
		_add(_sphere(0.17), mat, rig).position.y = _body_h + 0.12
	else:
		rig.add_child(model["node"])
		rim = ShaderMaterial.new()  # the player colour as a glow along the silhouette, the model still visible
		rim.shader = RIM_TINT
		for mi in CharacterModels.meshes(model["node"]):
			mi.material_overlay = rim
	var gun := _add(_box(Vector3(0.6, 0.08, 0.08)), _mat(Color.WHITE), rig)  # primitive figure only
	gun.position = Vector3(0.45, 1.15, 0.0)
	var label := _label(0.006)
	label.position.y = _actor_h + 0.45
	root.add_child(label)
	var ring := _add(_ring, _mat(Color.WHITE, true), root)
	ring.position.y = 0.03
	ring.scale = Vector3(0.4, 1.0, 0.4)
	ring.visible = slot == world.my_slot
	var mark := _add(_ring, _mat(Color(WorldView.PLAYER_COLORS[slot], 0.8), true), root)  # which officer: blue or orange underfoot
	mark.position.y = 0.028
	mark.scale = Vector3(0.33, 1.0, 0.33)
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
	_dynamic(root)
	return {
		"root": root, "rig": rig, "mat": mat, "model": model, "rim": rim, "gun": gun, "label": label, "cone": cone, "spot": spot,
		"beam": _add(_box(Vector3(0.02, 0.02, 1.0)), _mat(Color(1.0, 0.1, 0.1, 0.75), true)),
		"dot": _add(_sphere(0.05), _mat(Color(1.0, 0.2, 0.2), true))}


## NPC number `index`: its own look (clothes, skin, build, what it wears; PeopleLooks) on one of the
## model files of its kind (enemy, enemy_2, enemy_3 ... when they exist).
func _make_npc(a: NpcDirector.Agent, index: int) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var rig := Node3D.new()
	root.add_child(rig)
	var mat := _mat(WorldView.ENEMY_COLOR)
	var kind := "enemy" if a.brain.role == NpcBrain.Role.ENEMY else "civilian"
	var look := PeopleLooks.pick(kind, index, _cfg.get("people", {}))
	var names := CharacterModels.variants(kind, _cfg["characters"])
	var model_name: String = names[int(look["variant"]) % names.size()]
	var model := CharacterModels.make(model_name, _cfg["characters"])
	if not model.is_empty():
		for mi in CharacterModels.meshes(model["node"]):
			mi.layers = 2  # people take no decals (bullet holes, blood on the floor)
		PeopleLooks.apply(model, look)
	var separate_up := bool(_cfg["characters"]["surrender_model"])  # else the model itself raises its hands
	var model_up := CharacterModels.make(model_name + "_up", _cfg["characters"]) if separate_up and not model.is_empty() else {}
	if not model_up.is_empty():
		PeopleLooks.apply(model_up, look)
	if model.is_empty():
		_add(_capsule(), mat, rig).position.y = _body_h * 0.5
		_add(_sphere(0.17), mat, rig).position.y = _body_h + 0.12
	else:
		rig.add_child(model["node"])
		if not model_up.is_empty():  # hands up (surrender) as its own model
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
	var dropped: Node3D
	if model.is_empty():
		dropped = _add(_box(Vector3(0.5, 0.06, 0.1)), _mat(Color(1.0, 0.9, 0.3)), root)
		dropped.position = Vector3(0.3, 0.05, 0.35)
	else:  # the pistol itself on the floor, lit yellow so it still reads as the dropped-weapon cue
		var pistol := GearModels.make("pistol")
		var glow := _mat(Color(1.0, 0.85, 0.2, 0.45), true)
		glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pistol.material_overlay = glow
		pistol.transform = Transform3D(Basis(Vector3.UP, 0.6) * Basis(Vector3.BACK, PI * 0.5) * Basis.from_scale(Vector3.ONE * 1.3), Vector3(0.3, 0.025, 0.35))
		root.add_child(pistol)
		dropped = pistol
	var sil := _add(_capsule(), _mat(Color(0.35, 0.35, 0.4, 0.8), true), root)
	sil.position.y = _body_h * 0.5
	var marker := _label(0.012)
	marker.position.y = _actor_h + 0.6
	root.add_child(marker)
	var dbg := _label(0.005, Color(1, 1, 1, 0.85))
	dbg.position.y = 0.1
	root.add_child(dbg)
	_dynamic(root)
	return {"root": root, "rig": rig, "mat": mat, "model": model, "model_up": model_up, "cap": cap, "band": band, "gun": gun,
			"arms": arms, "cuffs": cuffs, "dropped": dropped, "sil": sil, "marker": marker, "dbg": dbg}


# ---- input ------------------------------------------------------------------

## Mouse wheel: zoom the camera in (closer to the figures) or out, within data/view3d.json camera
## zoom_min .. zoom_max (shares of distance_m).
func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var c: Dictionary = _cfg["camera"]
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		zoom_by(1.0 / float(c["zoom_step"]))
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		zoom_by(float(c["zoom_step"]))


func zoom_by(factor: float) -> void:
	var c: Dictionary = _cfg["camera"]
	_zoom_to = clampf(_zoom_to * factor, float(c["zoom_min"]), float(c["zoom_max"]))


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
	_wound_from_shot(shooter, from, to, _hit_npc)
	var m := _mat(Color(1.0, 0.35, 0.3) if shooter >= 2 else Color(1.0, 0.95, 0.5), true)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := _add(_box(Vector3(0.04, 0.04, 1.0)), m)
	var n: Dictionary = _players[shooter] if shooter < 2 else (_npcs[shooter - 2] if shooter - 2 < _npcs.size() else {})
	var muzzle := Vector3.INF
	if not n.is_empty():
		n["recoil"] = 1.0
		n["pop"] = 0.55  # someone in cover stands up to shoot for a moment
		muzzle = _gun_point(n["model"], "muzzle")
		var aim := _gun_dir(n["model"])
		if muzzle != Vector3.INF and aim != Vector3.ZERO:  # a short star of flame out of the barrel
			var fm := _mat(Color(1.0, 0.85, 0.45), true)
			fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			var cone := SphereMesh.new()
			cone.radius = 0.05
			cone.height = 0.1
			var fl := _add(cone, fm)
			fl.global_transform = Transform3D(Basis.looking_at(-aim, Vector3.UP) * Basis.from_scale(Vector3(1.0, 1.0, 2.6)), muzzle + aim * 0.1)  # long along the barrel
			_fx.append({"type": "muzzle", "node": fl, "mat": fm, "age": 0.0})
	_beam(mi, muzzle if muzzle != Vector3.INF else _p3(from, BEAM_Y), _p3(to, BEAM_Y))
	_fx.append({"type": "tracer", "node": mi, "mat": m, "age": 0.0})
	var mc: Dictionary = _cfg["lighting"]["muzzle"]  # the shot lights the room for a moment
	var flash := OmniLight3D.new()
	flash.light_energy = float(mc["energy"])
	flash.omni_range = float(mc["range_m"])
	flash.light_color = _col(mc["color"])
	flash.shadow_enabled = true
	flash.position = muzzle if muzzle != Vector3.INF else _p3(from, float(mc["height_m"]))
	add_child(flash)
	_fx.append({"type": "flash", "node": flash, "age": 0.0, "energy": float(mc["energy"]), "life": float(mc["life_s"])})
	_shot_marks(n, muzzle, to, _hit_npc)


func _on_speech(text: String, pos: Vector2, from_npc: bool) -> void:
	var l := _label(0.006, Color(1, 1, 0.8))
	l.text = text
	l.no_depth_test = true
	add_child(l)
	_fx.append({"type": "bubble", "node": l, "age": 0.0, "pos": pos, "npc": from_npc})


# ---- per frame --------------------------------------------------------------

func _process(delta: float) -> void:
	_t += delta
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
	_zoom = lerpf(_zoom, _zoom_to, minf(delta * 10.0, 1.0))
	off *= minf(_zoom, 1.0)  # zoomed in, look ahead less so the officer stays in view
	_cam_off = _cam_off.lerp(off, step)
	_cam_blend = move_toward(_cam_blend, 1.0 if me.cam_door >= 0 else 0.0, delta * 6.0)
	var target := (world.display_pos(world.my_slot) + _cam_off).lerp(view._vis_origin, _cam_blend)
	_cam_pos = target
	var c: Dictionary = _cfg["camera"]
	var pitch := deg_to_rad(float(c["pitch_deg"]))
	var at := _p3(_cam_pos)
	_cam.position = at + Vector3(0.0, sin(pitch), cos(pitch)) * float(c["distance_m"]) * _zoom
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
	_props_dirty = true
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
	if _props_dirty:  # furniture outside the sight polygon is hidden, like the walls
		_props_dirty = false
		for p in _props:
			(p["node"] as Node3D).visible = _in_sight(p["rect"])
	var me := world.display_pos(world.my_slot)
	var reach_per_m := 1.0 / tan(deg_to_rad(float(_cfg["camera"]["pitch_deg"]))) / _k  # px south a metre of height hides
	for p in _props:
		if int(p["wall"]) >= 0:
			(p["node"] as Node3D).scale.y = _wall_cut[int(p["wall"])]
		if p["tall"]:  # tall pieces in front of the officer are lowered like the walls (taller ones from further away)
			var r: Rect2 = p["rect"]
			var reach := maxf(float(_cfg["cutaway"]["reach_px"]), float((p["node"] as Node3D).get_meta("h", 1.0)) * reach_per_m)
			var hides := r.intersects(Rect2(me.x - 30.0, me.y, 60.0, reach))
			p["cut"] = lerpf(float(p["cut"]), float(_cfg["cutaway"]["low"]) if hides else 1.0, step)
			(p["node"] as Node3D).scale.y = p["cut"]
	_flash_police()
	for i in _doors.size():
		var d: Dictionary = _doors[i]
		var st := lv.get_door_state(i)
		var r := lv.door_rects[i]
		var span := r.grow_individual(r.size.x, 0, r.size.x, 0) if r.size.x >= r.size.y else r.grow_individual(0, r.size.y, 0, r.size.y)
		var seen := _in_sight(span)  # the opened leaf lies beside the opening
		var col := WorldView.DOOR_COLORS[lv.door_actor[i]]
		var target := 0.0
		if st == Level.DoorState.OPEN:
			target = float(d["open_deg"])
		elif st == Level.DoorState.AJAR:
			target = float(d["ajar_deg"])
		d["angle"] = move_toward(float(d["angle"]), target, delta * float(_cfg["doors"]["swing_dps"]))
		(d["pivot"] as Node3D).rotation.y = -float(d["zs"]) * deg_to_rad(float(d["angle"]))
		var root: Node3D = d["root"]
		root.visible = seen
		d["cut"] = lerpf(float(d["cut"]), _cut_target(span if st == Level.DoorState.OPEN else r), step)
		root.scale.y = d["cut"]
		# whoever touched the door last tints the wood (blue = host, orange = client)
		(d["leaf_mat"] as ShaderMaterial).set_shader_parameter("tint", Color.WHITE if lv.door_actor[i] == 0 else Color.WHITE.lerp(col, 0.6))
		# shadow caster over the leaf, up to the ceiling lights: light must not pass over a shut door.
		# Below that the leaf casts its own shadow (a caster round it would leave it in the dark).
		var shade: MeshInstance3D = d["shade"]
		var cr := lv.door_collider_rect(i)
		shade.visible = st != Level.DoorState.OPEN
		if shade.visible and cr != d["shade_rect"]:
			var caster_h := float(_cfg["lighting"]["shadow_caster_h"])
			var leaf_h := _wall_h * 0.9
			d["shade_rect"] = cr
			var horiz := r.size.x >= r.size.y
			var plane := cr.get_center()
			var thick := 0.05 / _k  # the leaf's thickness, on the face it swings to
			var across := 1 if horiz else 0
			plane[across] = (r.end[across] if float(d["swing"]) > 0.0 else r.position[across]) - float(d["swing"]) * thick * 0.5
			var sz := Vector3(cr.size.x * _k, caster_h - leaf_h, thick * _k) if horiz else Vector3(thick * _k, caster_h - leaf_h, cr.size.y * _k)
			(shade.mesh as BoxMesh).size = sz
			shade.position = _p3(plane, (caster_h + leaf_h) * 0.5)
		(d["mark"] as MeshInstance3D).visible = seen
		(d["mark_mat"] as StandardMaterial3D).albedo_color = Color(col, 0.5 if st == Level.DoorState.OPEN else 0.0)
		var lock: Node3D = d["lock"]
		lock.visible = seen and st != Level.DoorState.OPEN and lv.is_locked(i)
		lock.position = _p3(r.get_center(), _wall_h * float(d["cut"]) + 0.25 + sin(_t * 2.5) * 0.04)
		lock.rotation.y = _t * 1.2


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
		var lie := _fall(n, dead, delta)
		rig.basis = Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, PI * 0.5 * lie)
		rig.position.y = float(model.get("lie_y", LYING_Y)) * lie
		_pose_officer(ps, n, delta)
		var pm := n["mat"] as StandardMaterial3D
		pm.albedo_color = Color(0.5, 0.5, 0.5) if dead else WorldView.PLAYER_COLORS[s]
		pm.emission = pm.albedo_color * 0.3  # officers stay readable in a dark room
		if not model.is_empty():  # the two officers keep their colours (and stay readable in the dark): a rim glow, grey when dead
			var rim: ShaderMaterial = n["rim"]
			var cc: Dictionary = _cfg["characters"]
			rim.set_shader_parameter("tint", Color(0.5, 0.5, 0.5) if dead else WorldView.PLAYER_COLORS[s])
			rim.set_shader_parameter("even", 0.55 if dead else float(cc["player_tint"]))
			rim.set_shader_parameter("rim", 0.0 if dead else float(cc["player_rim"]))
		(n["gun"] as Node3D).visible = not dead and model.is_empty()
		var spot: SpotLight3D = n["spot"]
		spot.visible = ps.flash and not dead
		var light := _gun_point(model, "light")
		if light != Vector3.INF:  # the beam comes out of the weapon light
			spot.global_position = light
		else:
			spot.position = Vector3(0.3, float(_cfg["lighting"]["flash"]["height_m"]), 0.0)
		var text := "" if dead else "HP %d/%d" % [ps.hp, ps.max_hp]
		if ps.busy():
			text += "\n%s %d%%" % [WorldView.ACTION_LABELS[ps.action], int(100.0 * clampf(ps.action_t / ps.action_dur, 0.0, 1.0))]
		(n["label"] as Label3D).text = text
		(n["label"] as Label3D).pixel_size = 0.006 * _zoom  # same size on screen at any zoom
		_fan(n["cone"], view._cones[s], 0.02)
		var dot: Vector2 = view._laser_dots[s]
		var beam: MeshInstance3D = n["beam"]
		var dot_node: MeshInstance3D = n["dot"]
		dot_node.visible = dot != Vector2.INF
		if dot == Vector2.INF:
			beam.visible = false
		else:
			dot_node.position = _p3(dot, BEAM_Y)
			var muzzle := _gun_point(model, "muzzle")
			_beam(beam, muzzle if muzzle != Vector3.INF else _p3(at + Vector2.from_angle(ps.aim) * 18.0, BEAM_Y), dot_node.position)


func _update_npcs(delta: float) -> void:
	var S := NpcBrain.State
	var agents := world.director.agents
	for i in agents.size():
		var a: NpcDirector.Agent = agents[i]
		var n: Dictionary = _npcs[i]
		var root: Node3D = n["root"]
		if a.brain.state == NpcBrain.State.DEAD and not a.dormant:
			_pool(n, a, delta)
		var seen: int = view._npc_seen[i] if i < view._npc_seen.size() else LightModel.Seen.IDENTIFIED
		root.visible = not a.dormant and seen != LightModel.Seen.NONE
		if not root.visible:
			n.erase("pos")  # next appearance snaps to the sim position (and lies or stands at once)
			n.erase("walk_at")
			n.erase("lie")
			if not a.dormant and a.brain.alive() and not a.brain.state in [S.DOWN, S.HIDE, S.RESTRAINED]:
				_unseen_steps(n, a.pos, delta)
			continue
		n.erase("unseen_at")
		var sil := seen == LightModel.Seen.SILHOUETTE
		var fresh := not n.has("pos")
		root.position = _p3(_ease_pos(n, a.pos, delta))
		(n["sil"] as Node3D).visible = sil
		(n["rig"] as Node3D).visible = not sil
		(n["marker"] as Label3D).visible = not sil
		(n["dbg"] as Label3D).visible = not sil and view._debug
		if sil:
			(n["dropped"] as Node3D).visible = false
			n.erase("walk_at")
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
		if lying:  # a model lies face down (hands behind its head) when down, on its back when dead
			# down: face down, hands behind the head; dead: on its back, or on its face when the shot came
			# from behind (it falls away from the shooter)
			n["prone"] = not model.is_empty() and (st == S.DOWN or (st == S.DEAD and float(n.get("hit_from_z", 1.0)) < -0.25))
		var prone: bool = n.get("prone", false)
		var lie := _fall(n, lying, delta)
		rig.basis = Basis(Vector3.BACK, (-PI * 0.5 if prone else PI * 0.5) * lie)
		rig.position.y = (float(model["lie_front"]) if prone else float(model.get("lie_y", LYING_Y))) * lie
		if flash:
			n["flinch"] = 1.0
		if not model.is_empty():
			(model["node"] as Node3D).visible = not hands_up
			var tint := _npc_tint(st, flash)
			(model["overlay"] as StandardMaterial3D).albedo_color = tint
			if hands_up:
				(model_up["node"] as Node3D).visible = true
				(model_up["overlay"] as StandardMaterial3D).albedo_color = tint
			elif not model_up.is_empty():
				(model_up["node"] as Node3D).visible = false
		var shapes := model.is_empty()  # the primitive figure: squashed, with boxes for gun, cap, band, cuffs
		_pose_npc(a, n, model_up if hands_up else model, delta)  # (the primitive figure: only its stride)
		rig.scale = Vector3(1.0, 0.6 if st == S.HIDE and shapes else (0.65 if st == S.RESTRAINED and shapes else 1.0), 1.0)
		(n["cap"] as Node3D).visible = a.clues.has("cap") and shapes
		(n["band"] as Node3D).visible = a.clues.has("band") and shapes
		(n["gun"] as Node3D).visible = b.armed and st != S.DOWN and st != S.HIDE and st != S.DEAD and shapes
		(n["arms"] as Node3D).visible = st == S.SURRENDER and shapes
		(n["cuffs"] as Node3D).visible = st == S.RESTRAINED and shapes
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
		(n["marker"] as Label3D).pixel_size = (0.012 if marker in ["?", "!", "!!"] else 0.007) * _zoom  # symbols big, words smaller; same size on screen at any zoom
		(n["dbg"] as Label3D).pixel_size = 0.005 * _zoom
		var text: String = NpcBrain.STATE_NAMES[st]
		if b.feigning:
			text += " (가장)"
		if b.reason != "":
			text += ": " + b.reason
		(n["dbg"] as Label3D).text = text


## The walking part of a figure's pose, from what is drawn: the speed is how far the root moved this
## frame, so eased officers and NPCs step with their drawn motion, and the stride phase advances
## with distance. still: lying, hiding or restrained, no stride. Returns a CharacterAnim state
## ({"phase", "amount", "speed", "t", "seed"}); n["walk_v"] keeps the velocity (m/s, world).
func _stride(n: Dictionary, still: bool, delta: float) -> Dictionary:
	var g: Dictionary = _cfg["characters"]["walk"]
	var at := (n["root"] as Node3D).position
	var prev: Vector3 = n.get("walk_at", at)
	n["walk_at"] = at
	var step := Vector3(at.x - prev.x, 0.0, at.z - prev.z)
	var v := step / delta if delta > 0.0 and step.length() < 1.0 else Vector3.ZERO  # 1 m in a frame: teleported
	var vel: Vector3 = (n.get("walk_v", Vector3.ZERO) as Vector3).lerp(v, minf(delta * 12.0, 1.0))
	n["walk_v"] = vel
	var speed := vel.length()
	var amount := 0.0
	if not still:
		var target := clampf(inverse_lerp(float(g["start_mps"]), float(g["full_mps"]), speed), 0.0, 1.0)
		amount = lerpf(float(n.get("walk_amount", 0.0)), target, minf(delta * float(g["blend_rate"]), 1.0))
	n["walk_amount"] = amount
	var before := float(n.get("walk_phase", 0.0))
	var phase := fmod(before + TAU * speed * delta / (float(g["stride_m"]) + float(g["stride_per_mps"]) * speed), TAU)
	n["walk_phase"] = phase
	if amount > 0.35 and speed > float(g["start_mps"]) and foot_lands(before, phase):
		footstep.emit(Vector2(at.x, at.z) / _k, speed, int(n.get("who", -1)))
	return {"phase": phase, "amount": amount, "speed": speed, "t": _t, "dt": delta, "seed": float(n["root"].get_instance_id() % 97)}


## Did a foot land between stride phases a and b (radians, wrapping at TAU)? A leg reaches
## furthest forward, heel down, at PI / 2 and 3 PI / 2 (CharacterAnim swings the thigh with sin).
static func foot_lands(a: float, b: float) -> bool:
	for t: float in [PI * 0.5, PI * 1.5]:
		if (a < t and t <= b) or (b < a and (t > a or t <= b)):
			return true
	return false


## Steps of an NPC the officer cannot see (not drawn, so no walk cycle): the same stride from its
## simulated position, so footsteps behind walls are heard all the same.
func _unseen_steps(n: Dictionary, at: Vector2, delta: float) -> void:
	var g: Dictionary = _cfg["characters"]["walk"]
	var prev: Vector2 = n.get("unseen_at", at)
	n["unseen_at"] = at
	var speed := prev.distance_to(at) * _k / delta if delta > 0.0 and prev.distance_to(at) * _k < 1.0 else 0.0
	if speed <= float(g["start_mps"]):
		return
	var before := float(n.get("walk_phase", 0.0))
	var phase := fmod(before + TAU * speed * delta / (float(g["stride_m"]) + float(g["stride_per_mps"]) * speed), TAU)
	n["walk_phase"] = phase
	if foot_lands(before, phase):
		footstep.emit(at, speed, int(n.get("who", -1)))


## How far a figure has fallen (0 standing .. 1 lying), moving toward `lying` over pose fall_s: it
## topples faster and faster, and gets up smoothly. A figure first seen lying is down already.
func _fall(n: Dictionary, lying: bool, delta: float) -> float:
	var target := 1.0 if lying else 0.0
	var v := move_toward(float(n.get("lie", target)), target, delta / float(_cfg["characters"]["pose"]["fall_s"]))
	n["lie"] = v
	return v * v if lying else smoothstep(0.0, 1.0, v)


## A world direction in the model's own space (+Z its front), flattened; ZERO stays ZERO.
func _to_model(model: Dictionary, v: Vector3, flat := true) -> Vector3:
	var sk := model.get("skeleton") as Skeleton3D
	if sk == null or v.length_squared() < 1e-6:
		return Vector3.ZERO
	var d := sk.global_basis.inverse() * v
	if flat:
		d.y = 0.0
	return d.normalized()


## A gear node of `kind` on the model's skeleton, made the first time it is asked for.
func _gear(model: Dictionary, kind: String) -> Node3D:
	var have: Dictionary = model.get_or_add("gear_nodes", {})
	if not have.has(kind):
		var g := GearModels.make(kind)
		g.layers = 2
		g.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		PeopleLooks.tint(g, kind, model.get("look", {}))  # this person's hair, beanie, bag colour; the officer's patch
		(model["skeleton"] as Skeleton3D).add_child(g)
		have[kind] = g
	return have[kind]


## Shows the gear in `slots` ({slot: gear kind}, CharacterAnim's slots), hides the rest, poses.
func _pose(model: Dictionary, s: Dictionary, slots: Dictionary) -> void:
	if model.get("skeleton") == null:
		return
	var gear := {}
	for slot: String in slots:
		gear[slot] = _gear(model, slots[slot])
	for g: Node3D in (model.get_or_add("gear_nodes", {}) as Dictionary).values():
		g.visible = gear.values().has(g)
	model["gear"] = gear
	s["dir"] = _to_model(model, s.get("vel", Vector3.ZERO))
	CharacterAnim.pose(model, s, _cfg["characters"])


## A 0..1 cue that was set to 1 (n[key]: flinch on a hit, recoil on a shot), fading over pose[secs_key].
func _fade(n: Dictionary, key: String, secs_key: String, delta: float) -> float:
	var v := maxf(float(n.get(key, 0.0)) - delta / float(_cfg["characters"]["pose"][secs_key]), 0.0)
	n[key] = v
	return v


## An officer's pose: rifle or pistol on the aim (the other one slung or holstered), reloading,
## taking a knee to pick a lock, restrain or use the door camera, limp when dead.
func _pose_officer(ps: PlayerState, n: Dictionary, delta: float) -> void:
	var model: Dictionary = n["model"]
	var dead := ps.dead()
	var s := _stride(n, dead or ps.busy(), delta)  # (also for the plain figure: its footsteps)
	if model.get("skeleton") == null:
		return
	var S := CharacterAnim.Stance
	var H := CharacterAnim.Hold
	s["vel"] = n["walk_v"]
	s["flinch"] = _fade(n, "flinch", "flinch_s", delta)
	s["recoil"] = _fade(n, "recoil", "recoil_s", delta)
	var rifle: String = ps.weapon_kinds[0] if not ps.weapon_kinds.is_empty() else "rifle_lethal"
	var slots := {}
	if dead:
		s["stance"] = S.DEAD
		slots = {"holster": "pistol"}
	elif ps.busy():
		s["stance"] = S.WORK
		s["hold"] = H.WORK
		slots = {"back": rifle, "holster": "pistol"}
		if ps.action == PlayerState.ACTION_CAMERA:
			slots["hand"] = "camera"
	elif ps.active == 0:
		s["hold"] = H.RIFLE
		slots = {"hand": rifle, "holster": "pistol"}
	else:
		s["hold"] = H.PISTOL
		slots = {"hand": "pistol", "back": rifle}
	slots["patch"] = "patch"
	slots["radio"] = "radio"
	var w: WeaponState = ps.weapons[ps.active] if ps.active < ps.weapons.size() else null
	if w != null and w.reloading and not dead and not ps.busy():
		n["reload_t"] = float(n.get("reload_t", 0.0)) + delta
		s["reload"] = clampf(float(n["reload_t"]) / maxf(w.reload_time, 0.1), 0.0, 1.0)
	else:
		n["reload_t"] = 0.0
	_pose(model, s, slots)


## An NPC's pose from its state: pistol low or on the officer it threatens, startled hands, cowering
## with the head covered, kneeling cuffed, face down with hands behind the head, limp when dead;
## the head turns to the nearest officer while it reacts to one. Clues (cap, armband) are worn.
func _pose_npc(a: NpcDirector.Agent, n: Dictionary, model: Dictionary, delta: float) -> void:
	var S := NpcBrain.State
	var b := a.brain
	var st: int = b.state
	var s := _stride(n, st in [S.DOWN, S.DEAD, S.HIDE, S.RESTRAINED], delta)  # (also for the plain figure: its footsteps)
	if model.get("skeleton") == null:
		return
	var CS := CharacterAnim.Stance
	var H := CharacterAnim.Hold
	var scared := 0.0  # civilians shake when they give up or hide; a surrendered enemy a little
	if st in [S.SURRENDER, S.HIDE, S.DOWN, S.RESTRAINED]:
		scared = 1.0 if b.role == NpcBrain.Role.CIVILIAN else (0.35 if not b.armed else 0.0)
	s["tremble"] = lerpf(float(n.get("tremble", 0.0)), scared, minf(delta * 2.0, 1.0))
	n["tremble"] = s["tremble"]
	s["vel"] = n["walk_v"]
	s["flinch"] = _fade(n, "flinch", "flinch_s", delta)
	s["recoil"] = _fade(n, "recoil", "recoil_s", delta)
	var slots := {}
	for slot: String in ((model.get("look", {}) as Dictionary).get("acc", {}) as Dictionary):  # what this person wears
		slots[slot] = model["look"]["acc"][slot]
	if a.clues.has("cap"):
		slots["cap"] = "cap"
		slots.erase("hat")  # the red cap is the clue: nothing else on the head
	if a.clues.has("band"):
		slots["band"] = "band"
	var to_officer := Vector3.ZERO
	var near := _nearest_officer(a.pos)
	if b.aiming:  # holding an angle / waiting in ambush: along where it looks, not at an officer it cannot see
		to_officer = _to_model(model, _p3(Vector2.from_angle(b.facing) * 50.0, 0.0), false)
	elif near != Vector2.INF and st in [S.SPOTTED, S.THREAT, S.ATTACK, S.SURRENDER, S.FLEE]:
		to_officer = _to_model(model, _p3(near - a.pos, 0.0), false)
	match st:
		S.DEAD:
			s["stance"] = CS.DEAD
		S.DOWN:
			s["stance"] = CS.PRONE
			s["hold"] = H.HANDS_HEAD
		S.HIDE:
			s["stance"] = CS.CROUCH
			s["hold"] = H.COVER
			if b.armed:  # an enemy that fell back: crouched, gun ready
				s["hold"] = H.PISTOL_LOW
				slots["hand"] = "pistol"
		S.RESTRAINED:
			s["stance"] = CS.KNEEL
			s["hold"] = H.CUFFED
			slots["cuffs"] = "cuffs"
		S.SURRENDER:
			s["hold"] = H.HANDS_UP
		_:
			if b.armed:
				slots["hand"] = "pistol"
				s["hold"] = H.PISTOL_ONE if (st in [S.THREAT, S.ATTACK] or b.aiming) and to_officer != Vector3.ZERO else H.PISTOL_LOW
				n["pop"] = maxf(float(n.get("pop", 0.0)) - delta, 0.0)
				if b.in_cover and float(n["pop"]) <= 0.0:  # crouched behind furniture; rises to fire
					s["stance"] = CS.CROUCH
			elif st in [S.SPOTTED, S.THREAT, S.ATTACK]:
				s["hold"] = H.STARTLED
	if to_officer == Vector3.ZERO and st in [S.IDLE, S.INVESTIGATE] and not b.aiming:  # glancing around; searching harder
		var wide := 0.8 if st == S.INVESTIGATE else 0.45
		var turn := sin(_t * (0.9 if st == S.INVESTIGATE else 0.35) + float(s["seed"])) * wide
		s["look"] = Vector3(sin(turn), 0.0, cos(turn))
	else:
		s["look"] = to_officer
	s["aim"] = to_officer if to_officer != Vector3.ZERO else Vector3.BACK
	_pose(model, s, slots)


## The nearest living officer's position (px), or Vector2.INF.
func _nearest_officer(from: Vector2) -> Vector2:
	var best := Vector2.INF
	for ps in world.players:
		if ps.present and not ps.dead() and (best == Vector2.INF or from.distance_to(ps.pos) < from.distance_to(best)):
			best = ps.pos
	return best


## World position of a point of the gun in the model's hands ("muzzle" or "light"), or Vector3.INF.
func _gun_point(model: Dictionary, key: String) -> Vector3:
	var sk := model.get("skeleton") as Skeleton3D
	if sk == null or not model.has(key) or not sk.is_inside_tree():
		return Vector3.INF
	return sk.global_transform * (model[key] as Transform3D).origin


## World direction the gun in the model's hands points, or ZERO.
func _gun_dir(model: Dictionary) -> Vector3:
	var sk := model.get("skeleton") as Skeleton3D
	if sk == null or not model.has("muzzle") or not sk.is_inside_tree():
		return Vector3.ZERO
	return (sk.global_transform.basis * (model["muzzle"] as Transform3D).basis.z).normalized()


func _on_damaged(slot: int) -> void:
	if slot >= 0 and slot < _players.size():
		_players[slot]["flinch"] = 1.0
		var model: Dictionary = _players[slot]["model"]
		if not model.is_empty() and _last_npc_shot != Vector2.INF:  # blood on the officer's side facing the shooter
			var ps: PlayerState = world.players[slot]
			PeopleLooks.add_wound(model, _to_model(model, _p3(_last_npc_shot - world.display_pos(slot), 0.0)),
					randf_range(0.55, 0.8), float(_cfg["effects"]["wound"]["radius"]), randf_range(-1.0, 1.0))


## A shot that hit an NPC leaves a wound on it (on the side toward the shooter); a less-lethal round
## leaves none. NPC shots are remembered for the officer they may hit (_on_damaged).
func _wound_from_shot(shooter: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	if shooter >= 2:
		_last_npc_shot = from
		return
	if not hit_npc or shooter < 0 or shooter >= world.players.size():
		return
	var ps: PlayerState = world.players[shooter]
	if ps.weapon_kinds.size() > ps.active and ps.weapon_kinds[ps.active] == "rifle_nonlethal":
		return
	var best := -1
	var best_d := 40.0
	for i in mini(_npcs.size(), world.director.agents.size()):
		var d := world.director.agents[i].pos.distance_to(to)
		if d < best_d:
			best = i
			best_d = d
	if best < 0:
		return
	var model: Dictionary = _npcs[best]["model"]
	if model.is_empty():
		return
	var at := world.director.agents[best].pos
	var toward := _to_model(model, _p3(from - at, 0.0))
	if world.director.agents[best].brain.alive():
		_npcs[best]["hit_from_z"] = toward.z  # (a killing shot from behind drops it on its face)
	PeopleLooks.add_wound(model, toward, randf_range(0.52, 0.8), float(_cfg["effects"]["wound"]["radius"]), randf_range(-1.0, 1.0))


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
	_update_casings(delta)
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
			"muzzle":
				var k: float = f["age"] / float(_cfg["characters"]["pose"]["muzzle_s"])
				(f["mat"] as StandardMaterial3D).albedo_color.a = 1.0 - k
				done = k >= 1.0
			"burst":
				var k: float = f["age"] / f["life"]
				var kind: String = f["kind"]
				for bit: Dictionary in f["bits"]:
					var v: Vector3 = bit["vel"]
					if kind == "dust" or kind == "smoke":
						v *= 1.0 - minf(delta * 3.0, 0.9)  # air drag
						v.y += delta * 0.4
					else:
						v.y -= delta * 9.8
					bit["vel"] = v
					var bn: Node3D = bit["node"]
					bn.position += v * delta
					if kind == "dust" or kind == "smoke":
						bn.scale = Vector3.ONE * (1.0 + k * 2.5)
				(f["mat"] as StandardMaterial3D).albedo_color.a = float(f["alpha"]) * (1.0 - k)
				done = k >= 1.0
				if done:
					for bit: Dictionary in (f["bits"] as Array).slice(1):
						(bit["node"] as Node).queue_free()
			"tracer":
				var k: float = f["age"] / WorldView.TRACER_S
				(f["mat"] as StandardMaterial3D).albedo_color.a = 1.0 - k
				done = k >= 1.0
			"bubble":
				var life := WorldView.SPEECH_S
				var fade := 1.0 - clampf((float(f["age"]) - life * 0.7) / (life * 0.3), 0.0, 1.0)
				node.position = _p3(f["pos"], _actor_h + 0.9 + float(f["age"]) * 0.15)
				(node as Label3D).modulate.a = fade
				(node as Label3D).pixel_size = 0.006 * _zoom
				node.visible = not (f["npc"] and view._vis.size() >= 3 and not Geometry2D.is_point_in_polygon(f["pos"], view._vis))
				done = f["age"] >= life
		if done:
			node.queue_free()
		else:
			keep.append(f)
	_fx = keep


# ---- shot marks ---------------------------------------------------------------

## What a shot leaves: a hole and a puff of plaster where it hits a wall or a door, a spray of
## blood and a stain on the floor when it hits someone, smoke at the muzzle and a spent case
## thrown out of the gun's right side.
func _shot_marks(n: Dictionary, muzzle: Vector3, to: Vector2, hit_npc: bool) -> void:
	var fx: Dictionary = _cfg["effects"]
	if hit_npc:
		_burst(_p3(to, 1.15), Vector3.UP, _col(fx["blood"]), 9, 1.4, 0.4, 0.07, "blood")
		_stain(to + Vector2.from_angle(randf() * TAU) * randf_range(6.0, 20.0), randf_range(0.45, 0.7))
	else:
		var hit := _surface_hit(to)
		if not hit.is_empty():
			var nrm: Vector3 = hit["normal"]
			var at := Vector3(to.x * _k, minf(muzzle.y if muzzle != Vector3.INF else BEAM_Y, float(hit["top"]) - 0.08), to.y * _k)
			_hole(at, nrm)
			var debris := _col(fx["dust"])
			match str(hit["what"]):
				"soft":  # stuffing out of a sofa or a mattress
					debris = Color(0.85, 0.8, 0.7)
				"hard", "full":  # wood splinters
					debris = Color(0.5, 0.34, 0.2)
			_burst(at + nrm * 0.03, nrm, debris, 7, 1.6, 0.6, 0.09, "dust")
			if str(hit["what"]) != "soft":
				_burst(at + nrm * 0.02, nrm, Color(1.0, 0.8, 0.4), 5, 4.5, 0.12, 0.02, "spark")
	if muzzle != Vector3.INF:
		_burst(muzzle, Vector3.UP, Color(0.6, 0.6, 0.62, 0.5), 2, 0.25, 0.9, 0.12, "smoke")
	if not n.is_empty():
		_eject(n)


## {normal (3D, out of the face hit), top (m: how high the thing hit stands), what ("wall",
## "door", or the furniture's cover "full" / "hard" / "soft")} when p lies on a wall, a shut door
## or a piece of furniture that gives cover, else {}.
func _surface_hit(p: Vector2) -> Dictionary:
	var lv := world.level
	var rects: Array[Rect2] = []
	var info: Array = []
	for i in lv.props.size():  # furniture first: a bullet stopped by cover ends on it, next to a wall
		var c: String = lv.props[i]["cover"]
		if c != "":
			rects.append(lv.props[i]["rect"])
			info.append([c, float((_props[i]["node"] as Node3D).get_meta("h", 1.0)) if i < _props.size() else 1.0])
	for r in lv.wall_rects:
		rects.append(r)
		info.append(["wall", _wall_h])
	for i in lv.door_rects.size():
		if lv.get_door_state(i) != Level.DoorState.OPEN:
			rects.append(lv.door_collider_rect(i))
			info.append(["door", _wall_h * 0.9])
	for ri in rects.size():
		var r := rects[ri]
		if not r.grow(3.0).has_point(p):
			continue
		var d := [p.x - r.position.x, r.end.x - p.x, p.y - r.position.y, r.end.y - p.y]
		var normals := [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
		var best := 0
		for k in 4:
			if absf(d[k]) < absf(d[best]):
				best = k
		return {"normal": normals[best], "what": info[ri][0], "top": info[ri][1]}
	return {}


## A decal of texture `kind` laid on whatever is just behind `at` along -normal.
func _decal(kind: String, at: Vector3, normal: Vector3, size: float, depth: float) -> Decal:
	var d := Decal.new()
	d.texture_albedo = _effect_tex(kind)
	d.size = Vector3(size, depth, size)
	d.upper_fade = 0.05  # the default fades a surface a little off the box's middle away
	d.lower_fade = 0.05
	d.cull_mask = 1  # walls, floors, furniture; people and cases live on layer 2
	var y := normal.normalized()
	var x := (Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).cross(y).normalized()
	d.basis = Basis(y, randf() * TAU) * Basis(x, y, x.cross(y))  # local -Y projects into the surface; random turn
	d.position = at
	add_child(d)
	return d


func _hole(at: Vector3, normal: Vector3) -> void:
	_holes.append(_decal("hole", at, normal, randf_range(0.16, 0.22), 0.24))
	while _holes.size() > int(_cfg["effects"]["holes_max"]):
		_holes.pop_front().queue_free()


func _stain(p: Vector2, size: float) -> Decal:
	var d := _decal("blood", _p3(p, 0.04), Vector3.UP, size, 0.2)
	_stains.append(d)
	while _stains.size() > int(_cfg["effects"]["stains_max"]):
		_stains.pop_front().queue_free()
	return d


## A few soft sprites thrown out along `dir` that fade over `life`: "dust" and "smoke" slow down,
## rise and spread, "blood" drops fall, "spark" glows and falls fast.
func _burst(at: Vector3, dir: Vector3, color: Color, count: int, speed: float, life: float, size: float, kind: String) -> void:
	var glow := kind == "spark"
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = _effect_tex("puff")
	m.albedo_color = color
	if glow:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var q := QuadMesh.new()
	q.size = Vector2.ONE * size
	var bits: Array[Dictionary] = []
	for k in count:
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.position = at
		add_child(mi)
		var spread := Vector3(randf_range(-1, 1), randf_range(-0.3, 1), randf_range(-1, 1)) * 0.7
		bits.append({"node": mi, "vel": (dir + spread).normalized() * speed * randf_range(0.5, 1.0)})
	_fx.append({"type": "burst", "node": bits[0]["node"], "bits": bits, "mat": m, "age": 0.0, "life": life, "kind": kind, "alpha": color.a})


## A spent case out of the right side of the gun in the shooter's hands (people without a gun
## model throw none).
func _eject(n: Dictionary) -> void:
	var model: Dictionary = n.get("model", {})
	var gun := (model.get("gear", {}) as Dictionary).get("hand") as Node3D
	if gun == null or not gun.is_inside_tree() or not gun.visible or not gun.name.begins_with("rifle") and gun.name != "pistol":
		return
	if _casing_mesh == null:
		_casing_mesh = CylinderMesh.new()
		_casing_mesh.top_radius = 0.009  # a little larger than life so it reads from the top-down camera
		_casing_mesh.bottom_radius = 0.009
		_casing_mesh.height = 0.06
		_casing_mesh.radial_segments = 8
		_casing_mesh.rings = 1
		var brass := StandardMaterial3D.new()
		brass.albedo_color = Color(0.85, 0.62, 0.24)
		brass.metallic = 0.6
		brass.roughness = 0.3
		_casing_mesh.material = brass
	var mi := MeshInstance3D.new()
	mi.mesh = _casing_mesh
	mi.layers = 2
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var xf := gun.global_transform
	mi.global_position = xf * Vector3(0.0, 0.07, 0.06 if gun.name.begins_with("rifle") else 0.03)
	mi.rotation = Vector3(randf() * TAU, randf() * TAU, 0)
	var out := (xf.basis.orthonormalized() * Vector3(-1.0, 0.8, -0.35)).normalized()  # gun +X is its left
	var v := out * float(_cfg["effects"]["eject_mps"]) * randf_range(0.8, 1.2)
	_casings.append({"node": mi, "vel": v, "spin": Vector3(randf_range(-20, 20), randf_range(-20, 20), randf_range(-20, 20)), "rest": false})
	while _casings.size() > int(_cfg["effects"]["casings_max"]):
		(_casings.pop_front()["node"] as Node).queue_free()


## Cases fall, bounce once or twice on the floor and lie still on their side.
func _update_casings(delta: float) -> void:
	for c in _casings:
		if c["rest"]:
			continue
		var mi: MeshInstance3D = c["node"]
		var v: Vector3 = c["vel"]
		v.y -= 9.8 * delta
		var p := mi.position + v * delta
		mi.rotation += (c["spin"] as Vector3) * delta
		if p.y <= 0.027:
			p.y = 0.027
			if absf(v.y) > 0.7:
				v = Vector3(v.x * 0.45, -v.y * 0.3, v.z * 0.45)
				c["spin"] = (c["spin"] as Vector3) * 0.5
			else:
				c["rest"] = true
				p.y = 0.026
				mi.rotation = Vector3(PI * 0.5, randf() * TAU, 0)
		mi.position = p
		c["vel"] = v


## A dead body bleeds a pool that spreads under its chest over pool_s.
func _pool(n: Dictionary, a: NpcDirector.Agent, delta: float) -> void:
	var fx: Dictionary = _cfg["effects"]
	if not (n["model"] as Dictionary).is_empty():  # the clothes soak up more as it lies there
		PeopleLooks.spread_wounds(n["model"], delta * float(fx["wound"]["spread_per_s"]), float(fx["wound"]["max_radius"]))
	if not n.has("pool"):
		var chest := a.pos + Vector2(-0.8 / _k, 0.0).rotated(a.brain.facing)  # lying on its back, head behind it
		n["pool"] = {"decal": _stain(chest, 0.2), "age": 0.0}
	var pool: Dictionary = n["pool"]
	pool["age"] = float(pool["age"]) + delta
	var d: Decal = pool["decal"]
	if is_instance_valid(d):
		var k := clampf(float(pool["age"]) / float(fx["pool_s"]), 0.0, 1.0)
		var size := lerpf(0.2, float(fx["pool_m"]), 1.0 - pow(1.0 - k, 2.0))
		d.size = Vector3(size, 0.2, size)


## Generated textures: a bullet hole (dark core, chipped rim, cracks), a blood splash (a pool with
## droplets round it) and a soft round puff for dust, smoke and sparks. Made once per run.
func _effect_tex(kind: String) -> Texture2D:
	if _tex.has(kind):
		return _tex[kind]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind)
	var size := 64 if kind == "hole" or kind == "puff" or kind == "paper" else 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = 0.08
	var cracks: Array[float] = []
	for k in 6:
		cracks.append(rng.randf() * TAU)
	var drops: Array[Vector3] = []  # x, y, radius (0..1 of the half size)
	for k in 14:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.5, 0.92)
		drops.append(Vector3(cos(a) * r, sin(a) * r, rng.randf_range(0.03, 0.09)))
	for y in size:
		for x in size:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / (size * 0.5) - Vector2.ONE
			var r := u.length()
			var c := Color(0, 0, 0, 0)
			match kind:
				"hole":
					var nz := noise.get_noise_2d(x, y) * 0.5 + 0.5
					if r < 0.2 + nz * 0.06:
						c = Color(0.02, 0.02, 0.02, 1.0)
					elif r < 0.34 + nz * 0.1:
						c = Color(0.16, 0.15, 0.14, 0.9)  # scorched, torn edge
					elif r < 0.62 + nz * 0.15:
						c = Color(0.7, 0.68, 0.64, (1.0 - r / 0.8) * 0.85)  # bare plaster knocked off round it
					for a in cracks:
						var dir := Vector2.from_angle(a)
						var along := u.dot(dir)
						var off := absf(u.cross(dir))
						if along > 0.12 and along < 0.85 and off < 0.025 * (1.0 - along):
							c = Color(0.05, 0.05, 0.05, 0.85 * (1.0 - along))
				"blood":
					var edge := 0.5 + noise.get_noise_2d(x * 1.3, y * 1.3) * 0.18
					var a := 0.0
					if r < edge:
						a = 0.92
					for dp in drops:
						if u.distance_to(Vector2(dp.x, dp.y)) < dp.z:
							a = 0.85
					if a > 0.0:
						var shade := 0.75 + noise.get_noise_2d(x * 3.0, y * 3.0) * 0.25
						c = Color(0.5 * shade, 0.025, 0.02, a)
				"puff":
					var a := clampf(1.0 - r, 0.0, 1.0)
					c = Color(1, 1, 1, a * a)
				"grime":
					var a := smoothstep(0.75, 0.15, r + noise.get_noise_2d(x * 1.5, y * 1.5) * 0.45) * 0.28
					c = Color(0.16, 0.13, 0.1, a)
				"oil":
					var a := smoothstep(0.62, 0.45, r + noise.get_noise_2d(x * 1.2, y * 1.2) * 0.3) * 0.75
					c = Color(0.025, 0.025, 0.03, a)
				"water":
					var e := r + noise.get_noise_2d(x * 1.2, y * 1.2) * 0.2
					var a := smoothstep(0.62, 0.5, e) * 0.12 + smoothstep(0.04, 0.0, absf(e - 0.56)) * 0.35
					c = Color(0.2, 0.18, 0.15, a)
				"scuff":
					var a := 0.0
					for k in 7:
						var dir := Vector2.from_angle(cracks[k % cracks.size()] * 0.15 + float(k) * 0.07)
						var off := absf((u - Vector2(0.0, (float(k) - 3.0) * 0.18)).cross(dir))
						var along := absf(u.dot(dir))
						if off < 0.02 + 0.01 * sin(float(x) * 0.3 + k) and along < 0.6 + 0.2 * sin(k * 1.7):
							a = maxf(a, 0.3 * (1.0 - along))
					c = Color(0.06, 0.06, 0.06, a)
				"crack":
					var a := 0.0
					for k in cracks.size():
						var dir := Vector2.from_angle(cracks[k])
						var along := u.dot(dir)
						var wobble := noise.get_noise_2d(float(k) * 50.0 + along * 60.0, 0.0) * 0.12
						var off := absf(u.cross(dir) - wobble * along)
						if along > 0.0 and along < 0.55 + 0.4 * fmod(cracks[k], 1.0) and off < 0.018 * (1.0 - along):
							a = 0.85
					c = Color(0.06, 0.05, 0.05, a)
				"paper":
					var q := absf(u.x) < 0.66 and absf(u.y) < 0.86
					if q:
						var line := fmod(u.y + 1.0, 0.16) < 0.04 and u.y > -0.6 and u.y < 0.7 and absf(u.x) < 0.52 and fmod(u.x * 7.0 + float(int(u.y * 6.0)), 3.0) > 0.4
						c = Color(0.35, 0.36, 0.4, 1.0) if line else Color(0.9, 0.9, 0.86, 1.0)
				"streak":
					var col := noise.get_noise_2d(x * 0.9, 0.0) * 0.5 + 0.5
					var run := 0.2 + col * 1.6  # how far down this drip runs (from the top)
					var from_top := (u.y + 1.0) * 0.5 * 2.0
					var a := smoothstep(run, run - 0.6, from_top) * smoothstep(0.35, 0.75, col) * 0.4
					c = Color(0.07, 0.06, 0.05, a)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex[kind] = tex
	return tex


# ---- signs of use ---------------------------------------------------------------

## Marks that make the rooms look lived in, the same every run (seeded): grime in the corners,
## scuffs at the doors, cracks and stains on the walls, papers in the office and the corridor, a
## water ring by the sink, oil in the storeroom and on the street, rain streaks on the brick.
## Floor marks fade on upright faces (no smears up furniture legs).
func _build_wear() -> void:
	var lv := world.level
	var rng := RandomNumberGenerator.new()
	rng.seed = 9137
	var wc: Dictionary = _cfg["wear"]
	for rm in lv.rooms:
		var r: Rect2 = rm["rect"]
		var style := str(rm["floor"])
		var area := r.size.x * r.size.y * _k * _k
		for i in int(area * float(wc["grime_per_m2"])):  # grime gathers along the walls
			var p := _near_wall(r, rng, rng.randf_range(0.1, 0.7))
			_mark("grime", _p3(p, 0.03), Vector3.UP, rng.randf_range(0.5, 1.4), 0.3, rng)
		for i in int(wc["cracks_per_room"]):
			var face := _wall_spot(r, rng)
			if not face.is_empty():
				_mark("crack" if rng.randf() < 0.6 else "grime", face["at"] + Vector3(0, rng.randf_range(0.35, 1.3), 0), face["normal"], rng.randf_range(0.4, 0.8), 0.2, rng)
		var papers := int(wc["papers"].get(style, 0))
		for i in papers:
			var p := r.position + Vector2(rng.randf_range(0.15, 0.85) * r.size.x, rng.randf_range(0.15, 0.85) * r.size.y)
			_mark("paper", _p3(p, 0.03), Vector3.UP, rng.randf_range(0.22, 0.3), 0.3, rng)
		if style == "kitchen" or style == "concrete":
			for pr in lv.props:
				var kind := str(pr["kind"])
				if (kind == "sink" or kind == "fridge" or kind == "pallet" or kind == "workbench" or kind == "barrel") and r.encloses(pr["rect"]):
					var front: Vector2 = (pr["rect"] as Rect2).get_center().move_toward(r.get_center(), 32.0)
					_mark("water" if style == "kitchen" else "oil", _p3(front, 0.03), Vector3.UP, rng.randf_range(0.6, 1.0), 0.3, rng)
	for i in lv.door_rects.size():  # shoes scuff the floor where people go through
		var dr := lv.door_rects[i]
		var horiz := dr.size.x >= dr.size.y
		for side: float in [-1.0, 1.0]:
			var p := dr.get_center() + (Vector2(0, side * 26.0) if horiz else Vector2(side * 26.0, 0))
			if lv.building.has_point(p):
				_mark("scuff", _p3(p, 0.03), Vector3.UP, rng.randf_range(0.9, 1.3), 0.3, rng)
	var b := lv.building
	for i in int(wc["streaks_outside"]):  # rain runs down the brick from the top of the outer walls
		var face := _wall_spot(b, rng, true)
		if not face.is_empty():
			_mark("streak", face["at"] + Vector3(0, _wall_h * 0.62, 0), face["normal"], rng.randf_range(0.6, 1.0), 0.2, rng)
	for g in lv.ground:
		if str(g["surface"]) == "asphalt":
			var gr: Rect2 = g["rect"]
			for i in int(wc["oil_on_street"]):
				var p := gr.position + Vector2(rng.randf() * gr.size.x, rng.randf() * gr.size.y)
				_mark("oil", _p3(p, 0.02), Vector3.UP, rng.randf_range(0.5, 1.2), 0.3, rng)


## A point in room r, `off` m in from one of its walls, anywhere along it.
func _near_wall(r: Rect2, rng: RandomNumberGenerator, off: float) -> Vector2:
	var o := off / _k
	match rng.randi_range(0, 3):
		0: return Vector2(rng.randf_range(r.position.x, r.end.x), r.position.y + o)
		1: return Vector2(rng.randf_range(r.position.x, r.end.x), r.end.y - o)
		2: return Vector2(r.position.x + o, rng.randf_range(r.position.y, r.end.y))
	return Vector2(r.end.x - o, rng.randf_range(r.position.y, r.end.y))


## A spot on a wall face round rect r (its inside faces, or with `outside` the faces looking out),
## not in a doorway: {at (3D, on the floor line), normal}; {} when the try lands in a door.
func _wall_spot(r: Rect2, rng: RandomNumberGenerator, outside := false) -> Dictionary:
	var side := rng.randi_range(0, 3)
	var t := rng.randf_range(0.1, 0.9)
	var p: Vector2
	var n: Vector3
	match side:
		0:
			p = Vector2(lerpf(r.position.x, r.end.x, t), r.position.y)
			n = Vector3.FORWARD if outside else Vector3.BACK
		1:
			p = Vector2(lerpf(r.position.x, r.end.x, t), r.end.y)
			n = Vector3.BACK if outside else Vector3.FORWARD
		2:
			p = Vector2(r.position.x, lerpf(r.position.y, r.end.y, t))
			n = Vector3.LEFT if outside else Vector3.RIGHT
		_:
			p = Vector2(r.end.x, lerpf(r.position.y, r.end.y, t))
			n = Vector3.RIGHT if outside else Vector3.LEFT
	for dr in world.level.door_rects:
		if dr.grow(30.0).has_point(p):
			return {}
	return {"at": _p3(p), "normal": n}


func _mark(kind: String, at: Vector3, normal: Vector3, size: float, depth: float, rng: RandomNumberGenerator) -> void:
	var d := Decal.new()
	d.texture_albedo = _effect_tex(kind)
	d.size = Vector3(size, depth, size)
	d.upper_fade = 0.05
	d.lower_fade = 0.05
	d.normal_fade = 0.5
	d.cull_mask = 1
	d.modulate = Color(1, 1, 1, rng.randf_range(0.7, 1.0))
	var y := normal.normalized()
	var x := (Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).cross(y).normalized()
	var spin := rng.randf() * TAU if kind != "streak" else 0.0  # streaks run down
	d.basis = Basis(y, spin) * Basis(x, y, x.cross(y))
	d.position = at
	add_child(d)
	_wear.append(d)
