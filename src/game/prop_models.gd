extends RefCounted
## Furniture, door leaves and frames, the padlock and the police car for the 3D view, built from
## boxes, cylinders and spheres (no asset files) and sized to the map: make(kind, w, d) returns a
## MeshInstance3D whose origin is the middle of the footprint on the floor, front toward +Z, w wide
## (X) and d deep (Z), in meters. Metadata: "h" (height, m); the police car also "lights" (light bar
## red and blue points) and "light_mats" (their two materials, which the view flashes).
## A model file assets/props/<set>/<kind>.glb replaces a shape (set_name: data/view3d.json
## characters.set): it is scaled evenly to fit the footprint and stood on the floor, front +Z.
## Meshes are cached per kind and size, so equal pieces share one. Guide for model files:
## docs/09-3d-models-antigravity.md. No class_name: preloaded (see character_models.gd).

const CharacterModels := preload("res://src/game/character_models.gd")
const SURFACE := preload("res://src/game/surface.gdshader")
const SurfaceMaps := preload("res://src/game/surface_maps.gd")
const DIR := "res://assets/props/"
## Kinds make() knows (anything else is drawn as a plain crate).
const KINDS: Array[String] = ["sofa", "armchair", "coffee_table", "dining_table", "desk", "office_chair", "chair", "tv_stand",
	"bookshelf", "wardrobe", "dresser", "bed", "nightstand", "plant", "floor_lamp", "picture", "whiteboard", "filing_cabinet",
	"water_cooler", "printer_table", "fridge", "counter", "island", "sink", "stove", "pantry", "trash_bin", "shelving", "crate", "pallet",
	"workbench", "barrel", "cone", "rug", "police_car", "padlock", "street_lamp"]
## Pieces the view lowers with the walls when they stand between the camera and the officer:
## tall enough to hide a person, or hung on a wall.
const TALL: Array[String] = ["bookshelf", "wardrobe", "fridge", "pantry", "shelving", "workbench", "water_cooler", "floor_lamp",
	"picture", "whiteboard"]  # (a street lamp stays up: lowered, its arm would lie across the street)

static var folder := DIR
static var tex_folder := "res://assets/textures/"  ## photo textures of furniture materials (SurfaceMaps), e.g. <set>/wood_mid.png
static var set_name := ""
static var _meshes: Dictionary = {}  ## "<kind>|<w>|<d>" -> [ArrayMesh, metadata]
static var _mats: Dictionary = {}


## A new node showing `kind` on a w x d footprint (meters). lit false: lamp shades and screens are
## switched off (a dark room has no light on).
static func make(kind: String, w: float, d: float, lit := true) -> MeshInstance3D:
	var key := "%s|%.2f|%.2f|%s" % [kind, w, d, lit]
	if not _meshes.has(key):
		var built: Array = _from_file(kind, w, d) if set_name != "" else []
		_meshes[key] = built if not built.is_empty() else _build(kind, w, d, key, lit)
	var mi := MeshInstance3D.new()
	mi.name = kind
	mi.mesh = _meshes[key][0]
	var meta: Dictionary = _meshes[key][1]
	for k: String in meta:
		mi.set_meta(k, meta[k])
	if kind == "police_car" and not meta.has("file"):
		for side: float in [-1.0, 1.0]:  # POLICE on both front doors
			var l := Label3D.new()
			l.text = "POLICE"
			l.font_size = 64
			l.pixel_size = 0.004
			l.outline_size = 0
			l.modulate = Color(0.08, 0.15, 0.45)
			l.position = Vector3(side * (w * 0.5 + 0.006), 0.62, 0.35)
			l.rotation_degrees.y = 90.0 * side
			mi.add_child(l)
	return mi


## A door leaf w wide and h tall (hinge edge at the origin, leaf along +X, centred on Z), with
## raised panels, lever handles, hinges and a kick plate. meta "wood": index of the wood surface
## (the view gives each door its own tinted copy of that material).
static func door_leaf(w: float, h: float, t: float) -> MeshInstance3D:
	var key := "door|%.2f|%.2f|%.3f" % [w, h, t]
	if not _meshes.has(key):
		var b := Builder.new()
		b.box(Vector3(w, h, t), "door_wood", Vector3(w * 0.5, h * 0.5, 0))
		var cols := 2 if w > 1.1 else 1
		var pw := (w - 0.12 - 0.08 * (cols - 1)) / cols
		var rows: Array[float] = [0.42, 0.24, 0.42]  # bottom, middle, top panel shares of the panel height
		var ph_total := h - 0.36
		for side: float in [-1.0, 1.0]:
			var y := 0.18
			for r in rows.size():
				var ph := ph_total * rows[r] - 0.06
				for c in cols:
					var x := 0.06 + pw * 0.5 + c * (pw + 0.08)
					b.box(Vector3(pw - 0.04, ph, 0.012), "door_wood", Vector3(x, y + ph * 0.5, side * (t * 0.5 + 0.006)))
					b.box(Vector3(pw, ph + 0.04, 0.004), "door_trim", Vector3(x, y + ph * 0.5, side * (t * 0.5 + 0.002)))
				y += ph + 0.06
			b.box(Vector3(w - 0.04, 0.16, 0.004), "steel", Vector3(w * 0.5, 0.1, side * (t * 0.5 + 0.002)))  # kick plate
			# lever handle near the free edge, at hand height
			b.box(Vector3(0.05, 0.12, 0.012), "chrome", Vector3(w - 0.09, h * 0.62, side * (t * 0.5 + 0.006)))
			b.tube(0.011, 0.04, "chrome", Vector3(w - 0.09, h * 0.62 + 0.02, side * (t * 0.5 + 0.03)), Vector3(90, 0, 0), 8)
			b.box(Vector3(0.13, 0.022, 0.022), "chrome", Vector3(w - 0.14, h * 0.62 + 0.02, side * (t * 0.5 + 0.05)))
		for y: float in [0.2, h * 0.5, h - 0.2]:  # hinges
			b.tube(0.012, 0.11, "steel", Vector3(0.0, y, 0.0), Vector3.ZERO, 8)
		var mesh := _commit(b)
		_meshes[key] = [mesh, {"h": h, "wood": b.keys().find("door_wood")}]
	var mi := MeshInstance3D.new()
	mi.name = "leaf"
	mi.mesh = _meshes[key][0]
	mi.set_meta("wood", _meshes[key][1]["wood"])
	return mi


## The frame round a door opening `w` wide in a wall `depth` thick and `wall_h` tall: painted
## casing on both faces and the wall piece above the door (from leaf_h up). Origin at the middle
## of the opening on the floor, opening along X.
static func door_frame(w: float, depth: float, wall_h: float, leaf_h: float) -> MeshInstance3D:
	var key := "frame|%.2f|%.2f|%.2f|%.2f" % [w, depth, wall_h, leaf_h]
	if not _meshes.has(key):
		var b := Builder.new()
		var lintel := wall_h - leaf_h
		b.box(Vector3(w, lintel, depth), "plaster", Vector3(0, leaf_h + lintel * 0.5, 0))
		b.box(Vector3(w + 0.02, 0.012, depth + 0.02), "cap", Vector3(0, wall_h + 0.006, 0))
		for side: float in [-1.0, 1.0]:
			for end: float in [-1.0, 1.0]:  # side casings, standing proud of the wall
				b.box(Vector3(0.07, leaf_h + 0.07, 0.02), "trim", Vector3(end * (w * 0.5 + 0.035), (leaf_h + 0.07) * 0.5, side * (depth * 0.5 + 0.01)))
			b.box(Vector3(w + 0.14, 0.07, 0.02), "trim", Vector3(0, leaf_h + 0.035, side * (depth * 0.5 + 0.01)))
		for end: float in [-1.0, 1.0]:  # jamb linings inside the opening
			b.box(Vector3(0.02, leaf_h, depth), "trim", Vector3(end * (w * 0.5 - 0.01), leaf_h * 0.5, 0))
		b.box(Vector3(w, 0.015, depth), "threshold", Vector3(0, 0.0075, 0))
		_meshes[key] = [_commit(b), {"h": wall_h}]
	var mi := MeshInstance3D.new()
	mi.name = "frame"
	mi.mesh = _meshes[key][0]
	return mi


## Drops the shared meshes (at quit).
static func release() -> void:
	_meshes.clear()
	_mats.clear()


static func is_tall(kind: String) -> bool:
	return TALL.has(kind)


# ---- materials --------------------------------------------------------------

static func mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: Material
	match key:
		"wood_dark":
			m = _wood(Color(0.24, 0.14, 0.075), Color(0.14, 0.075, 0.035), 0.11)
		"wood_mid":
			m = _wood(Color(0.46, 0.3, 0.16), Color(0.32, 0.19, 0.09), 0.1)
		"wood_light":
			m = _wood(Color(0.7, 0.55, 0.36), Color(0.55, 0.4, 0.24), 0.1)
		"crate_wood":
			m = _wood(Color(0.66, 0.53, 0.33), Color(0.5, 0.38, 0.22), 0.13)
		"door_wood":
			m = _wood(Color(0.45, 0.29, 0.16), Color(0.32, 0.19, 0.1), 0.16)
		"fabric_grey":
			m = _cloth(Color(0.36, 0.37, 0.38), Color(0.27, 0.28, 0.29))
		"fabric_green":
			m = _cloth(Color(0.24, 0.33, 0.28), Color(0.17, 0.25, 0.2))
		"fabric_blue":
			m = _cloth(Color(0.17, 0.24, 0.44), Color(0.12, 0.17, 0.33))
		"fabric_red":
			m = _cloth(Color(0.5, 0.13, 0.1), Color(0.36, 0.08, 0.07))
		"fabric_beige":
			m = _cloth(Color(0.66, 0.58, 0.44), Color(0.52, 0.45, 0.33))
		"linen":
			m = _cloth(Color(0.88, 0.87, 0.83), Color(0.78, 0.77, 0.73))
		"stone":
			m = _surface(0, Color(0.2, 0.2, 0.21), Color(0.36, 0.35, 0.34), 28.0, 0.15, 0.4)
		"plaster":
			m = _surface(0, Color(0.7, 0.68, 0.63), Color(0.6, 0.58, 0.54), 1.1, 0.75, 1.0)
		_:
			m = _plain(key)
	if m is ShaderMaterial:  # a photo of this wood or cloth in the set replaces the pattern (1 m per picture)
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("tex_m", 1.0)
		SurfaceMaps.apply(sm, tex_folder, set_name, key)
	_mats[key] = m
	return m


static func _surface(mode: int, a: Color, b: Color, scale: float, r0: float, r1: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("color_a", a)
	m.set_shader_parameter("color_b", b)
	m.set_shader_parameter("scale", scale)
	m.set_shader_parameter("rough_min", r0)
	m.set_shader_parameter("rough_max", r1)
	m.set_shader_parameter("bump", 0.02)
	m.set_shader_parameter("object_space", true)
	return m


static func _wood(a: Color, b: Color, plank: float) -> ShaderMaterial:
	var m := _surface(2, a, b, 1.0, 0.45, 0.75)
	m.set_shader_parameter("tile_m", plank)
	m.set_shader_parameter("grout", a.darkened(0.7))
	return m


static func _cloth(a: Color, b: Color) -> ShaderMaterial:
	var m := _surface(0, a, b, 22.0, 0.85, 1.0)
	m.set_shader_parameter("bump", 0.04)
	return m


static func _plain(key: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var c := Color(0.5, 0.5, 0.5)
	var rough := 0.6
	var metal := 0.0
	var glow := Color.BLACK
	var glow_e := 0.0
	match key:
		"white": c = Color(0.86, 0.86, 0.84); rough = 0.45
		"offwhite": c = Color(0.76, 0.74, 0.69); rough = 0.55
		"trim": c = Color(0.84, 0.82, 0.78); rough = 0.4
		"cap": c = Color(0.1, 0.1, 0.11); rough = 0.9
		"threshold": c = Color(0.3, 0.25, 0.18); rough = 0.5
		"door_trim": c = Color(0.2, 0.12, 0.06); rough = 0.6
		"black": c = Color(0.04, 0.04, 0.045); rough = 0.45
		"dark_grey": c = Color(0.16, 0.16, 0.17); rough = 0.6
		"grey_metal": c = Color(0.42, 0.43, 0.45); rough = 0.45; metal = 0.5
		"steel": c = Color(0.68, 0.69, 0.71); rough = 0.3; metal = 0.6
		"chrome": c = Color(0.85, 0.86, 0.88); rough = 0.15; metal = 0.7
		"rubber": c = Color(0.03, 0.03, 0.03); rough = 0.9
		"screen": c = Color(0.04, 0.06, 0.09); rough = 0.1; glow = Color(0.2, 0.32, 0.5); glow_e = 0.5
		"glass": c = Color(0.08, 0.11, 0.13); rough = 0.05; metal = 0.3
		"water": c = Color(0.45, 0.65, 0.9); rough = 0.05
		"leaf": c = Color(0.13, 0.33, 0.11); rough = 0.75
		"leaf2": c = Color(0.2, 0.42, 0.15); rough = 0.75
		"terracotta": c = Color(0.56, 0.26, 0.15); rough = 0.85
		"soil": c = Color(0.1, 0.07, 0.05); rough = 1.0
		"cardboard": c = Color(0.56, 0.43, 0.27); rough = 0.95
		"tape": c = Color(0.7, 0.6, 0.4); rough = 0.4
		"shade": c = Color(0.95, 0.9, 0.76); rough = 0.8; glow = Color(1.0, 0.82, 0.55); glow_e = 0.9
		"shade_off": c = Color(0.7, 0.66, 0.56); rough = 0.8
		"screen_off": c = Color(0.02, 0.02, 0.025); rough = 0.1
		"orange": c = Color(0.95, 0.38, 0.05); rough = 0.6
		"reflect": c = Color(0.9, 0.9, 0.9); rough = 0.3; glow = Color(0.9, 0.9, 0.9); glow_e = 0.15
		"paper": c = Color(0.93, 0.93, 0.9); rough = 0.8
		"art0": c = Color(0.2, 0.36, 0.55)
		"art1": c = Color(0.8, 0.55, 0.2)
		"art2": c = Color(0.55, 0.15, 0.18)
		"book0": c = Color(0.5, 0.1, 0.08)
		"book1": c = Color(0.1, 0.18, 0.42)
		"book2": c = Color(0.12, 0.3, 0.15)
		"book3": c = Color(0.65, 0.52, 0.33)
		"book4": c = Color(0.08, 0.08, 0.09)
		"book5": c = Color(0.85, 0.82, 0.74)
		"red": c = Color(0.7, 0.08, 0.06); rough = 0.5
		"blue": c = Color(0.08, 0.2, 0.6); rough = 0.5
		"yellow": c = Color(0.9, 0.7, 0.1); rough = 0.5
		"barrel": c = Color(0.1, 0.26, 0.55); rough = 0.5; metal = 0.3
		"car_white": c = Color(0.9, 0.9, 0.92); rough = 0.25
		"car_black": c = Color(0.03, 0.03, 0.035); rough = 0.25
		"headlight": c = Color(0.95, 0.95, 0.9); glow = Color(1.0, 0.97, 0.88); glow_e = 1.5
		"taillight": c = Color(0.6, 0.02, 0.02); glow = Color(1.0, 0.05, 0.03); glow_e = 0.8
		"bar_red": c = Color(0.5, 0.02, 0.02); glow = Color(1.0, 0.05, 0.03); glow_e = 0.2
		"bar_blue": c = Color(0.02, 0.05, 0.5); glow = Color(0.1, 0.3, 1.0); glow_e = 0.2
		"lock_red": c = Color(0.85, 0.08, 0.06); glow = Color(1.0, 0.08, 0.05); glow_e = 0.7; rough = 0.3
		"street_glow": c = Color(0.9, 0.94, 1.0); glow = Color(0.85, 0.92, 1.0); glow_e = 3.0
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if glow_e > 0.0:
		m.emission_enabled = true
		m.emission = glow
		m.emission_energy_multiplier = glow_e
	if key == "water":
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a = 0.55
	return m


# ---- building ----------------------------------------------------------------

## Collects primitive parts per material and merges them into one ArrayMesh (one surface per
## material, materials from PropModels.mat()).
class Builder:
	var tools: Dictionary = {}  ## material key -> SurfaceTool
	var order: Array[String] = []
	var dark := false  ## lamp shades and screens off

	func add(mesh: PrimitiveMesh, key: String, xf: Transform3D) -> void:
		if not tools.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[key] = st
			order.append(key)
		(tools[key] as SurfaceTool).append_from(mesh, 0, xf)

	func _xf(at: Vector3, rot_deg: Vector3, scale := Vector3.ONE) -> Transform3D:
		return Transform3D(Basis.from_euler(rot_deg * (PI / 180.0)) * Basis.from_scale(scale), at)

	func box(size: Vector3, key: String, at: Vector3, rot_deg := Vector3.ZERO) -> void:
		var m := BoxMesh.new()
		m.size = size
		add(m, key, _xf(at, rot_deg))

	## A cylinder standing along Y (rot_deg turns it).
	func tube(radius: float, length: float, key: String, at: Vector3, rot_deg := Vector3.ZERO, sides := 14) -> void:
		cone(radius, radius, length, key, at, rot_deg, sides)

	func cone(bottom: float, top: float, length: float, key: String, at: Vector3, rot_deg := Vector3.ZERO, sides := 14) -> void:
		var m := CylinderMesh.new()
		m.bottom_radius = bottom
		m.top_radius = top
		m.height = length
		m.radial_segments = sides
		m.rings = 1
		add(m, key, _xf(at, rot_deg))

	func ball(radius: float, key: String, at: Vector3, scale := Vector3.ONE) -> void:
		var m := SphereMesh.new()
		m.radius = radius
		m.height = radius * 2.0
		m.radial_segments = 12
		m.rings = 6
		add(m, key, _xf(at, Vector3.ZERO, scale))

	func ring(inner: float, outer: float, key: String, at: Vector3, rot_deg := Vector3.ZERO) -> void:
		var m := TorusMesh.new()
		m.inner_radius = inner
		m.outer_radius = outer
		m.rings = 20
		m.ring_segments = 6
		add(m, key, _xf(at, rot_deg))

	func keys() -> Array[String]:
		return order

	## One surface per material key, in the order of keys() (materials: PropModels._commit).
	func commit() -> ArrayMesh:
		var out := ArrayMesh.new()
		for key in order:
			(tools[key] as SurfaceTool).commit(out)
		return out


## The builder's mesh with every surface given its material.
static func _commit(b: Builder) -> ArrayMesh:
	var out := b.commit()
	for i in out.get_surface_count():
		var key := b.order[i]
		if b.dark and (key == "shade" or key == "screen"):
			key += "_off"
		out.surface_set_material(i, mat(key))
	return out


static func _build(kind: String, w: float, d: float, key: String, lit: bool) -> Array:
	var b := Builder.new()
	b.dark = not lit
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var meta := {}
	var h := 0.8
	match kind:
		"sofa", "armchair":
			h = _sofa(b, w, d, 1 if kind == "armchair" else maxi(1, roundi((w - 0.32) / 0.62)), "fabric_green" if kind == "sofa" else "fabric_red")
		"coffee_table":
			h = _table(b, w, d, 0.42, "wood_dark", true)
		"dining_table", "table":
			h = _table(b, w, d, 0.75, "wood_mid", false)
			b.box(Vector3(w * 0.55, 0.006, d * 0.35), "offwhite", Vector3(0, 0.753, 0))  # table runner
			b.tube(0.07, 0.05, "white", Vector3(0, 0.78, 0), Vector3.ZERO, 12)  # bowl
			b.ball(0.035, "orange", Vector3(0.02, 0.81, 0.01))
			b.ball(0.033, "red", Vector3(-0.03, 0.81, -0.01))
		"desk":
			h = _desk(b, w, d)
		"printer_table":
			h = _table(b, w, d, 0.72, "grey_metal", false)
			b.box(Vector3(0.46, 0.22, 0.36), "offwhite", Vector3(0, 0.83, 0))
			b.box(Vector3(0.4, 0.02, 0.2), "dark_grey", Vector3(0, 0.95, -0.05))
			b.box(Vector3(0.24, 0.005, 0.18), "paper", Vector3(0, 0.75, 0.24 - 0.09))
		"office_chair":
			h = _office_chair(b, w, d)
		"chair":
			h = _chair(b, w, d)
		"tv_stand":
			h = _tv_stand(b, w, d)
		"bookshelf":
			h = _bookshelf(b, w, d, rng)
		"wardrobe", "pantry":
			h = _cabinet(b, w, d, 1.9, 2 if w > 0.9 else 1, "wood_light" if kind == "wardrobe" else "white", true)
		"dresser":
			h = _drawers(b, w, d, 0.85, 3, "wood_dark")
			b.cone(0.05, 0.03, 0.2, "white", Vector3(w * 0.25, 0.95, 0), Vector3.ZERO, 10)  # vase
			b.box(Vector3(w * 0.3, 0.02, 0.2), "art0", Vector3(-w * 0.15, 0.86, 0))  # folded clothes
		"filing_cabinet":
			h = _drawers(b, w, d, 1.3, 4, "grey_metal")
		"nightstand":
			h = _drawers(b, w, d, 0.55, 2, "wood_dark")
			_lamp(b, Vector3(0, h, 0), 0.32)
		"bed":
			h = _bed(b, w, d)
		"plant":
			h = _plant(b, w, d, rng)
		"floor_lamp":
			b.tube(minf(w, d) * 0.4, 0.03, "black", Vector3(0, 0.015, 0))
			b.tube(0.012, 1.45, "black", Vector3(0, 0.75, 0), Vector3.ZERO, 8)
			_lamp_shade(b, Vector3(0, 1.45, 0), minf(w, d) * 0.5, 0.26)
			h = 1.6
		"picture":
			h = _picture(b, w, d, rng)
		"whiteboard":
			h = _whiteboard(b, w, d, rng)
		"water_cooler":
			b.box(Vector3(w * 0.9, 0.95, d * 0.9), "white", Vector3(0, 0.475, 0))
			b.box(Vector3(w * 0.5, 0.08, 0.02), "dark_grey", Vector3(0, 0.8, d * 0.45 + 0.01))
			b.tube(0.012, 0.03, "red", Vector3(-0.05, 0.78, d * 0.45 + 0.02), Vector3(90, 0, 0), 8)
			b.tube(0.012, 0.03, "blue", Vector3(0.05, 0.78, d * 0.45 + 0.02), Vector3(90, 0, 0), 8)
			b.tube(minf(w, d) * 0.38, 0.38, "water", Vector3(0, 1.14, 0))
			b.tube(minf(w, d) * 0.3, 0.04, "blue", Vector3(0, 1.35, 0))
			h = 1.37
		"fridge":
			h = _fridge(b, w, d)
		"counter", "island", "sink", "stove":
			h = _counter(b, w, d, kind)
		"trash_bin":
			b.cone(minf(w, d) * 0.42, minf(w, d) * 0.48, 0.6, "dark_grey", Vector3(0, 0.3, 0))
			b.cone(minf(w, d) * 0.5, minf(w, d) * 0.46, 0.04, "black", Vector3(0, 0.62, 0))
			h = 0.64
		"shelving":
			h = _shelving(b, w, d, rng)
		"crate":
			h = _crate(b, w, d)
		"pallet":
			h = _pallet(b, w, d, rng)
		"workbench":
			h = _workbench(b, w, d)
		"barrel":
			var r := minf(w, d) * 0.48
			b.tube(r, 0.88, "barrel", Vector3(0, 0.44, 0), Vector3.ZERO, 18)
			for y: float in [0.03, 0.3, 0.58, 0.85]:
				b.ring(r - 0.006, r + 0.012, "barrel", Vector3(0, y, 0))
			b.tube(r * 0.15, 0.015, "dark_grey", Vector3(r * 0.5, 0.885, 0), Vector3.ZERO, 8)
			h = 0.88
		"cone":
			var s := minf(w, d)
			b.box(Vector3(s, 0.03, s), "black", Vector3(0, 0.015, 0))
			b.cone(s * 0.38, s * 0.07, 0.45, "orange", Vector3(0, 0.255, 0))
			b.cone(s * 0.27, s * 0.2, 0.08, "reflect", Vector3(0, 0.28, 0))
			h = 0.48
		"rug":
			b.box(Vector3(w, 0.008, d), "fabric_red", Vector3(0, 0.004, 0))
			b.box(Vector3(w - 0.14, 0.01, d - 0.14), "fabric_beige", Vector3(0, 0.005, 0))
			b.box(Vector3(w - 0.3, 0.012, d - 0.3), "fabric_red", Vector3(0, 0.006, 0))
			b.box(Vector3(minf(w, d) * 0.35, 0.014, minf(w, d) * 0.35), "fabric_blue", Vector3(0, 0.007, 0), Vector3(0, 45, 0))
			h = 0.014
		"police_car":
			h = _police_car(b, w, d, meta)
		"street_lamp":  # pole with an arm reaching forward (+Z); meta "lamp": where its light hangs
			b.tube(0.16, 0.3, "dark_grey", Vector3(0, 0.15, 0), Vector3.ZERO, 12)
			b.cone(0.085, 0.06, 4.2, "dark_grey", Vector3(0, 2.25, 0), Vector3.ZERO, 12)
			b.box(Vector3(0.08, 0.08, 1.3), "dark_grey", Vector3(0, 4.3, 0.6), Vector3(-6, 0, 0))
			b.box(Vector3(0.3, 0.12, 0.55), "dark_grey", Vector3(0, 4.22, 1.25))
			b.box(Vector3(0.24, 0.02, 0.45), "street_glow", Vector3(0, 4.155, 1.25))
			meta["lamp"] = Vector3(0, 4.05, 1.25)
			h = 4.4
		"padlock":
			b.box(Vector3(0.12, 0.1, 0.05), "lock_red", Vector3(0, 0.05, 0))
			b.ring(0.035, 0.05, "steel", Vector3(0, 0.1, 0), Vector3(90, 0, 0))
			h = 0.15
		_:
			h = _crate(b, w, d)
	meta["h"] = h
	return [_commit(b), meta]


static func _legs(b: Builder, w: float, d: float, h: float, r: float, key: String, inset: float) -> void:
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			b.box(Vector3(r, h, r), key, Vector3(sx * (w * 0.5 - inset), h * 0.5, sz * (d * 0.5 - inset)))


static func _sofa(b: Builder, w: float, d: float, seats: int, cloth: String) -> float:
	var arm := 0.16
	_legs(b, w, d, 0.08, 0.05, "wood_dark", 0.06)
	b.box(Vector3(w, 0.22, d), cloth, Vector3(0, 0.19, 0))  # frame
	b.box(Vector3(w, 0.5, 0.18), cloth, Vector3(0, 0.55, -d * 0.5 + 0.09))  # back
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(arm, 0.32, d), cloth, Vector3(side * (w * 0.5 - arm * 0.5), 0.46, 0))
		b.tube(arm * 0.5, d, cloth, Vector3(side * (w * 0.5 - arm * 0.5), 0.62, 0), Vector3(90, 0, 0), 10)  # rolled arm top
	var inner := w - 2.0 * arm
	var cw := inner / seats
	for i in seats:
		var x := -inner * 0.5 + cw * (i + 0.5)
		b.box(Vector3(cw - 0.02, 0.13, d - 0.24), cloth, Vector3(x, 0.365, 0.05))  # seat cushion
		b.box(Vector3(cw - 0.03, 0.36, 0.14), cloth, Vector3(x, 0.6, -d * 0.5 + 0.24), Vector3(-10, 0, 0))  # back cushion
	if seats > 1:
		b.box(Vector3(0.36, 0.3, 0.1), "fabric_beige", Vector3(-inner * 0.5 + 0.25, 0.56, -d * 0.5 + 0.34), Vector3(-15, 0, 12))  # throw pillow
	return 0.85


static func _table(b: Builder, w: float, d: float, h: float, wood: String, shelf: bool) -> float:
	b.box(Vector3(w, 0.04, d), wood, Vector3(0, h - 0.02, 0))
	b.box(Vector3(w - 0.1, 0.08, d - 0.1), wood, Vector3(0, h - 0.08, 0))  # apron
	_legs(b, w, d, h - 0.04, 0.05, wood, 0.06)
	if shelf:
		b.box(Vector3(w - 0.12, 0.02, d - 0.12), wood, Vector3(0, 0.12, 0))
		b.box(Vector3(0.2, 0.03, 0.15), "art1", Vector3(w * 0.2, h + 0.015, 0.02), Vector3(0, 12, 0))  # magazines
		b.box(Vector3(0.18, 0.01, 0.12), "art0", Vector3(-w * 0.2, h + 0.005, -0.03), Vector3(0, -20, 0))  # remote
	return h


static func _desk(b: Builder, w: float, d: float) -> float:
	var h := 0.75
	b.box(Vector3(w, 0.03, d), "wood_light", Vector3(0, h - 0.015, 0))
	b.box(Vector3(0.03, h - 0.03, d), "wood_light", Vector3(-w * 0.5 + 0.015, (h - 0.03) * 0.5, 0))
	b.box(Vector3(w - 0.03, 0.35, 0.02), "wood_light", Vector3(0.015, h - 0.2, -d * 0.5 + 0.01))  # modesty panel
	var dw := 0.42
	b.box(Vector3(dw, h - 0.03, d), "wood_light", Vector3(w * 0.5 - dw * 0.5, (h - 0.03) * 0.5, 0))
	for i in 3:  # drawer fronts with pulls
		var y := 0.12 + i * 0.21
		b.box(Vector3(dw - 0.04, 0.18, 0.01), "wood_mid", Vector3(w * 0.5 - dw * 0.5, y + 0.09, d * 0.5 + 0.005))
		b.box(Vector3(0.12, 0.015, 0.015), "chrome", Vector3(w * 0.5 - dw * 0.5, y + 0.15, d * 0.5 + 0.015))
	# monitor, keyboard, mouse, papers, mug
	b.box(Vector3(0.22, 0.015, 0.16), "black", Vector3(-0.05, h + 0.008, -d * 0.5 + 0.16))
	b.box(Vector3(0.04, 0.22, 0.03), "black", Vector3(-0.05, h + 0.12, -d * 0.5 + 0.14))
	b.box(Vector3(0.56, 0.34, 0.03), "black", Vector3(-0.05, h + 0.36, -d * 0.5 + 0.17), Vector3(-6, 0, 0))
	b.box(Vector3(0.52, 0.3, 0.005), "screen", Vector3(-0.05, h + 0.36, -d * 0.5 + 0.187), Vector3(-6, 0, 0))
	b.box(Vector3(0.42, 0.02, 0.14), "dark_grey", Vector3(-0.05, h + 0.01, d * 0.5 - 0.2), Vector3(0, 2, 0))
	b.box(Vector3(0.06, 0.02, 0.1), "dark_grey", Vector3(0.28, h + 0.01, d * 0.5 - 0.2))
	b.box(Vector3(0.21, 0.006, 0.29), "paper", Vector3(-w * 0.5 + 0.2, h + 0.003, 0.0), Vector3(0, -8, 0))
	b.box(Vector3(0.21, 0.006, 0.29), "paper", Vector3(-w * 0.5 + 0.23, h + 0.008, 0.02), Vector3(0, 5, 0))
	b.tube(0.04, 0.1, "white", Vector3(w * 0.5 - 0.15, h + 0.05, -0.05), Vector3.ZERO, 12)
	return h


static func _office_chair(b: Builder, w: float, d: float) -> float:
	var s := minf(w, d)
	for i in 5:  # star base with casters
		var a := TAU * i / 5.0
		var dir := Vector3(sin(a), 0, cos(a))
		b.box(Vector3(0.04, 0.03, s * 0.45), "black", dir * s * 0.22 + Vector3(0, 0.07, 0), Vector3(0, rad_to_deg(a), 0))
		b.ball(0.025, "black", dir * s * 0.44 + Vector3(0, 0.03, 0))
	b.tube(0.025, 0.33, "chrome", Vector3(0, 0.25, 0), Vector3.ZERO, 10)
	b.box(Vector3(s * 0.9, 0.07, s * 0.85), "black", Vector3(0, 0.46, 0.02))
	b.box(Vector3(s * 0.86, 0.55, 0.06), "black", Vector3(0, 0.8, -s * 0.42), Vector3(-8, 0, 0))
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(0.04, 0.03, s * 0.45), "dark_grey", Vector3(side * s * 0.45, 0.66, 0.0))
		b.box(Vector3(0.03, 0.18, 0.03), "dark_grey", Vector3(side * s * 0.45, 0.57, -0.06))
	return 1.08


static func _chair(b: Builder, w: float, d: float) -> float:
	_legs(b, w * 0.9, d * 0.9, 0.44, 0.035, "wood_mid", 0.03)
	b.box(Vector3(w * 0.92, 0.04, d * 0.92), "wood_mid", Vector3(0, 0.46, 0))
	b.box(Vector3(w * 0.84, 0.03, d * 0.84), "fabric_beige", Vector3(0, 0.49, 0.0))
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(0.035, 0.46, 0.035), "wood_mid", Vector3(side * (w * 0.45 - 0.03), 0.7, -d * 0.45 + 0.02))
	b.box(Vector3(w * 0.88, 0.12, 0.025), "wood_mid", Vector3(0, 0.86, -d * 0.45 + 0.02))
	b.box(Vector3(w * 0.88, 0.05, 0.02), "wood_mid", Vector3(0, 0.66, -d * 0.45 + 0.02))
	return 0.92


static func _tv_stand(b: Builder, w: float, d: float) -> float:
	b.box(Vector3(w, 0.45, d), "wood_dark", Vector3(0, 0.25, 0))
	b.box(Vector3(w, 0.05, d - 0.04), "black", Vector3(0, 0.025, -0.02))  # plinth
	for i in 3:
		var x := -w * 0.5 + w / 3.0 * (i + 0.5)
		b.box(Vector3(w / 3.0 - 0.03, 0.36, 0.01), "wood_mid", Vector3(x, 0.26, d * 0.5 + 0.005))
		b.box(Vector3(0.1, 0.012, 0.012), "chrome", Vector3(x, 0.4, d * 0.5 + 0.015))
	var tw := minf(w * 0.92, 1.3)
	b.box(Vector3(0.3, 0.02, 0.18), "black", Vector3(0, 0.485, 0))
	b.box(Vector3(0.06, 0.1, 0.04), "black", Vector3(0, 0.54, 0))
	b.box(Vector3(tw, tw * 0.58, 0.04), "black", Vector3(0, 0.6 + tw * 0.29, 0.0))
	b.box(Vector3(tw - 0.03, tw * 0.58 - 0.03, 0.005), "screen", Vector3(0, 0.6 + tw * 0.29, 0.022))
	b.box(Vector3(0.4, 0.07, 0.1), "black", Vector3(w * 0.3, 0.51, 0.02))  # game console
	return 0.6 + tw * 0.58


static func _bookshelf(b: Builder, w: float, d: float, rng: RandomNumberGenerator) -> float:
	var h := 1.8
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(0.025, h, d), "wood_dark", Vector3(side * (w * 0.5 - 0.0125), h * 0.5, 0))
	b.box(Vector3(w, 0.02, d), "wood_dark", Vector3(0, h - 0.01, 0))
	b.box(Vector3(w - 0.05, h, 0.01), "wood_dark", Vector3(0, h * 0.5, -d * 0.5 + 0.005))
	var shelves := 5
	for i in shelves:
		var y := 0.06 + i * (h - 0.08) / shelves
		b.box(Vector3(w - 0.05, 0.02, d - 0.01), "wood_dark", Vector3(0, y, 0.005))
		var x := -w * 0.5 + 0.035
		while x < w * 0.5 - 0.08:
			var bw := rng.randf_range(0.022, 0.05)
			var bh := rng.randf_range(0.18, 0.28)
			var lean := rng.randf_range(-6.0, 6.0) if rng.randf() < 0.15 else 0.0
			b.box(Vector3(bw, bh, d * rng.randf_range(0.62, 0.8)), "book%d" % rng.randi_range(0, 5), Vector3(x + bw * 0.5, y + 0.01 + bh * 0.5, 0.0), Vector3(0, 0, lean))
			x += bw + 0.003
			if rng.randf() < 0.07:
				x += rng.randf_range(0.06, 0.14)  # a gap, an ornament
	return h


static func _cabinet(b: Builder, w: float, d: float, h: float, doors: int, wood: String, crown: bool) -> float:
	b.box(Vector3(w, h - 0.06, d), wood, Vector3(0, 0.06 + (h - 0.06) * 0.5, 0))
	b.box(Vector3(w - 0.04, 0.06, d - 0.04), "black", Vector3(0, 0.03, -0.02))
	if crown:
		b.box(Vector3(w + 0.03, 0.04, d + 0.02), wood, Vector3(0, h - 0.02, 0.01))
	var dw := (w - 0.02) / doors
	for i in doors:
		var x := -w * 0.5 + 0.01 + dw * (i + 0.5)
		b.box(Vector3(dw - 0.012, h - 0.16, 0.012), wood, Vector3(x, 0.06 + (h - 0.12) * 0.5, d * 0.5 + 0.006))
		var hx := x + (dw * 0.5 - 0.05) * (1.0 if i % 2 == 0 and doors > 1 else -1.0)
		if doors == 1:
			hx = x + dw * 0.5 - 0.05
		b.box(Vector3(0.015, 0.22, 0.02), "chrome", Vector3(hx, h * 0.55, d * 0.5 + 0.022))
	return h


static func _drawers(b: Builder, w: float, d: float, h: float, n: int, wood: String) -> float:
	b.box(Vector3(w, h - 0.05, d), wood, Vector3(0, 0.05 + (h - 0.05) * 0.5, 0))
	b.box(Vector3(w - 0.04, 0.05, d - 0.04), "black", Vector3(0, 0.025, -0.02))
	b.box(Vector3(w + 0.02, 0.025, d + 0.02), wood, Vector3(0, h - 0.0125, 0.0))
	var dh := (h - 0.1) / n
	for i in n:
		var y := 0.06 + dh * (i + 0.5)
		b.box(Vector3(w - 0.04, dh - 0.015, 0.012), wood, Vector3(0, y, d * 0.5 + 0.006))
		b.box(Vector3(minf(w * 0.35, 0.14), 0.015, 0.018), "chrome", Vector3(0, y + dh * 0.15, d * 0.5 + 0.02))
	return h


static func _bed(b: Builder, w: float, d: float) -> float:
	_legs(b, w, d, 0.12, 0.06, "wood_dark", 0.05)
	b.box(Vector3(w, 0.2, d), "wood_dark", Vector3(0, 0.22, 0))  # frame
	b.box(Vector3(w, 0.95, 0.07), "wood_dark", Vector3(0, 0.475, -d * 0.5 + 0.035))  # headboard
	b.box(Vector3(w - 0.12, 0.6, 0.02), "fabric_beige", Vector3(0, 0.62, -d * 0.5 + 0.075))  # padding
	b.box(Vector3(w, 0.45, 0.05), "wood_dark", Vector3(0, 0.225, d * 0.5 - 0.025))  # footboard
	b.box(Vector3(w - 0.06, 0.2, d - 0.1), "linen", Vector3(0, 0.42, 0.0))  # mattress
	for side: float in [-1.0, 1.0]:  # pillows
		b.box(Vector3(w * 0.5 - 0.1, 0.11, 0.32), "linen", Vector3(side * (w * 0.25 - 0.01), 0.575, -d * 0.5 + 0.28), Vector3(-12, 0, 0))
	var bl := d * 0.66
	b.box(Vector3(w - 0.02, 0.07, bl), "fabric_blue", Vector3(0, 0.555, d * 0.5 - 0.05 - bl * 0.5))  # blanket
	for side: float in [-1.0, 1.0]:  # hanging over the sides
		b.box(Vector3(0.02, 0.24, bl), "fabric_blue", Vector3(side * (w * 0.5 - 0.005), 0.45, d * 0.5 - 0.05 - bl * 0.5))
	b.box(Vector3(w - 0.01, 0.09, 0.14), "linen", Vector3(0, 0.57, d * 0.5 - 0.05 - bl + 0.06))  # folded sheet edge
	return 0.95


static func _lamp(b: Builder, at: Vector3, tall: float) -> void:
	b.tube(0.06, 0.02, "chrome", at + Vector3(0, 0.01, 0), Vector3.ZERO, 12)
	b.tube(0.01, tall * 0.6, "chrome", at + Vector3(0, tall * 0.3, 0), Vector3.ZERO, 8)
	_lamp_shade(b, at + Vector3(0, tall * 0.6, 0), 0.11, tall * 0.4)


static func _lamp_shade(b: Builder, at: Vector3, r: float, tall: float) -> void:
	b.cone(r, r * 0.65, tall, "shade", at + Vector3(0, tall * 0.5, 0), Vector3.ZERO, 16)


static func _plant(b: Builder, w: float, d: float, rng: RandomNumberGenerator) -> float:
	var r := minf(w, d) * 0.42
	b.cone(r * 0.75, r, 0.36, "terracotta", Vector3(0, 0.18, 0), Vector3.ZERO, 16)
	b.tube(r * 1.04, 0.04, "terracotta", Vector3(0, 0.36, 0), Vector3.ZERO, 16)
	b.tube(r * 0.95, 0.01, "soil", Vector3(0, 0.37, 0), Vector3.ZERO, 16)
	for i in 3:
		b.tube(0.012, 0.4 + i * 0.12, "wood_mid", Vector3((i - 1) * 0.03, 0.55 + i * 0.06, 0), Vector3(0, 0, (i - 1) * 8.0), 6)
	for i in 11:
		var a := rng.randf() * TAU
		var rad := rng.randf_range(0.0, r * 1.2)
		var y := rng.randf_range(0.6, 1.05)
		b.ball(rng.randf_range(0.09, 0.15), "leaf" if i % 2 == 0 else "leaf2", Vector3(cos(a) * rad, y, sin(a) * rad), Vector3(1.0, 0.75, 1.0))
	return 1.15


static func _picture(b: Builder, w: float, d: float, rng: RandomNumberGenerator) -> float:
	var ph := minf(w * 0.75, 0.5)
	var y := 1.15
	var z := -d * 0.5 + 0.015
	b.box(Vector3(w, ph, 0.03), "black" if rng.randf() < 0.5 else "wood_dark", Vector3(0, y, z))
	b.box(Vector3(w - 0.07, ph - 0.07, 0.005), "white", Vector3(0, y, z + 0.016))
	b.box(Vector3(w - 0.14, ph - 0.14, 0.006), "art%d" % rng.randi_range(0, 2), Vector3(0, y, z + 0.018))
	b.box(Vector3((w - 0.14) * 0.5, (ph - 0.14) * 0.45, 0.007), "art%d" % rng.randi_range(0, 2), Vector3(-(w - 0.14) * 0.2, y - ph * 0.12, z + 0.019))
	b.ball((ph - 0.14) * 0.12, "art1", Vector3((w - 0.14) * 0.25, y + ph * 0.15, z + 0.02), Vector3(1, 1, 0.1))
	return y + ph * 0.5


static func _whiteboard(b: Builder, w: float, d: float, rng: RandomNumberGenerator) -> float:
	var ph := 0.8
	var y := 1.15
	var z := -d * 0.5 + 0.015
	b.box(Vector3(w, ph, 0.025), "steel", Vector3(0, y, z))
	b.box(Vector3(w - 0.04, ph - 0.04, 0.005), "white", Vector3(0, y, z + 0.014))
	b.box(Vector3(w * 0.8, 0.03, 0.06), "steel", Vector3(0, y - ph * 0.5 - 0.01, z + 0.03))
	for i in 6:  # scribbles: a plan of the house, arrows
		var c := ["blue", "red", "black"][rng.randi_range(0, 2)] as String
		b.box(Vector3(rng.randf_range(0.1, 0.45), 0.012, 0.004), c, Vector3(rng.randf_range(-w * 0.3, w * 0.3), y + rng.randf_range(-0.25, 0.28), z + 0.018), Vector3(0, 0, rng.randf_range(-40, 40)))
	b.box(Vector3(0.12, 0.018, 0.018), "blue", Vector3(-w * 0.2, y - ph * 0.5 + 0.01, z + 0.04))
	return y + ph * 0.5


static func _fridge(b: Builder, w: float, d: float) -> float:
	var h := 1.8
	b.box(Vector3(w, h - 0.04, d), "steel", Vector3(0, 0.04 + (h - 0.04) * 0.5, 0))
	b.box(Vector3(w - 0.03, 0.04, d - 0.04), "black", Vector3(0, 0.02, -0.02))
	b.box(Vector3(w - 0.01, 0.006, 0.01), "black", Vector3(0, 1.22, d * 0.5 + 0.004))  # freezer gap
	for y: Array in [[1.5, 0.4], [0.75, 0.6]]:
		b.box(Vector3(0.025, y[1], 0.03), "chrome", Vector3(w * 0.5 - 0.06, y[0], d * 0.5 + 0.03))
	b.box(Vector3(0.08, 0.1, 0.004), "yellow", Vector3(-0.1, 1.05, d * 0.5 + 0.003), Vector3(0, 0, 8))  # notes
	b.box(Vector3(0.08, 0.08, 0.004), "paper", Vector3(0.0, 0.95, d * 0.5 + 0.003), Vector3(0, 0, -5))
	return h


static func _counter(b: Builder, w: float, d: float, kind: String) -> float:
	var h := 0.9
	b.box(Vector3(w, 0.1, d - 0.08), "black", Vector3(0, 0.05, -0.04))  # recessed kick
	b.box(Vector3(w, h - 0.14, d - 0.03), "white", Vector3(0, 0.1 + (h - 0.14) * 0.5, -0.015))
	if kind == "stove":
		b.box(Vector3(w - 0.04, 0.5, 0.012), "black", Vector3(0, 0.42, d * 0.5 - 0.02))  # oven door glass
		b.box(Vector3(w - 0.1, 0.02, 0.03), "chrome", Vector3(0, 0.7, d * 0.5 - 0.0))
		b.box(Vector3(w, 0.03, d), "black", Vector3(0, h - 0.015, 0))
		for i in 4:
			var x := (i % 2 - 0.5) * w * 0.48
			var z := (i / 2 - 0.5) * d * 0.48
			b.ring(0.04, 0.07, "dark_grey", Vector3(x, h + 0.005, z))
		for i in 4:
			b.tube(0.014, 0.02, "chrome", Vector3((i - 1.5) * w * 0.2, h - 0.08, d * 0.5 + 0.005), Vector3(90, 0, 0), 8)
		return h
	var doors := maxi(1, roundi(w / 0.5))
	var dw := w / doors
	for i in doors:
		var x := -w * 0.5 + dw * (i + 0.5)
		b.box(Vector3(dw - 0.012, 0.18, 0.012), "white", Vector3(x, h - 0.17, d * 0.5 - 0.024))  # drawer
		b.box(Vector3(dw - 0.012, h - 0.38, 0.012), "white", Vector3(x, 0.1 + (h - 0.38) * 0.5 + 0.02, d * 0.5 - 0.024))
		b.box(Vector3(0.12, 0.012, 0.015), "chrome", Vector3(x, h - 0.15, d * 0.5 - 0.01))
		b.box(Vector3(0.012, 0.12, 0.015), "chrome", Vector3(x + dw * 0.35, 0.55, d * 0.5 - 0.01))
	if kind == "island":  # free-standing: the top overhangs the back for stools, a fruit bowl instead of a kettle
		b.box(Vector3(w + 0.04, 0.04, d + 0.12), "stone", Vector3(0, h - 0.02, -0.06))
		b.box(Vector3(0.3, 0.02, 0.22), "wood_light", Vector3(-w * 0.2, h + 0.01, 0.03), Vector3(0, 10, 0))  # cutting board
		b.cone(0.07, 0.13, 0.07, "white", Vector3(w * 0.25, h + 0.035, -0.05))  # bowl
		for i in 3:
			b.ball(0.035, ["orange", "red", "orange"][i], Vector3(w * 0.25 + (i - 1) * 0.05, h + 0.08, -0.05 + (i % 2) * 0.03))
		return h
	b.box(Vector3(w, 0.04, d), "stone", Vector3(0, h - 0.02, 0))
	b.box(Vector3(w, 0.5, 0.012), "white", Vector3(0, h + 0.25, -d * 0.5 + 0.006))  # splash-back tiles
	if kind == "sink":
		b.box(Vector3(w * 0.7, 0.012, d * 0.6), "steel", Vector3(0, h + 0.001, 0.02))
		b.box(Vector3(w * 0.6, 0.014, d * 0.5), "dark_grey", Vector3(0, h + 0.002, 0.02))
		b.tube(0.014, 0.25, "chrome", Vector3(0, h + 0.125, -d * 0.5 + 0.08), Vector3.ZERO, 8)
		b.tube(0.012, 0.16, "chrome", Vector3(0, h + 0.25, -d * 0.5 + 0.15), Vector3(90, 0, 0), 8)
	else:
		b.box(Vector3(0.3, 0.02, 0.22), "wood_light", Vector3(-w * 0.2, h + 0.01, 0.03), Vector3(0, 10, 0))  # cutting board
		b.box(Vector3(0.26, 0.2, 0.18), "dark_grey", Vector3(w * 0.3, h + 0.1, -0.03))  # microwave / kettle base
		b.box(Vector3(0.18, 0.12, 0.004), "black", Vector3(w * 0.28, h + 0.1, 0.062))
	return h


static func _shelving(b: Builder, w: float, d: float, rng: RandomNumberGenerator) -> float:
	var h := 1.8
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			b.box(Vector3(0.035, h, 0.035), "grey_metal", Vector3(sx * (w * 0.5 - 0.018), h * 0.5, sz * (d * 0.5 - 0.018)))
	for i in 5:
		var y := 0.1 + i * 0.4
		b.box(Vector3(w, 0.02, d), "grey_metal", Vector3(0, y, 0))
		if i == 4:
			continue
		var x := -w * 0.5 + 0.05
		while x < w * 0.5 - 0.15:
			var bw := rng.randf_range(0.18, 0.4)
			if x + bw > w * 0.5 - 0.04:
				break
			if rng.randf() < 0.7:
				var bh := rng.randf_range(0.16, 0.32)
				b.box(Vector3(bw, bh, d * rng.randf_range(0.6, 0.9)), "cardboard", Vector3(x + bw * 0.5, y + 0.01 + bh * 0.5, 0), Vector3(0, rng.randf_range(-4, 4), 0))
				b.box(Vector3(bw + 0.002, 0.012, 0.04), "tape", Vector3(x + bw * 0.5, y + 0.01 + bh, 0), Vector3(0, rng.randf_range(-4, 4), 0))
			else:
				for k in 2:
					b.tube(0.08, 0.2, "grey_metal" if k == 0 else "red", Vector3(x + 0.09 + k * 0.17, y + 0.11, 0), Vector3.ZERO, 12)
			x += bw + rng.randf_range(0.02, 0.08)
	return h


static func _crate(b: Builder, w: float, d: float) -> float:
	var h := minf(w, d) * 0.9
	b.box(Vector3(w - 0.02, h - 0.02, d - 0.02), "crate_wood", Vector3(0, h * 0.5, 0))
	var t := 0.05
	for face: Array in [[Vector3(0, 0, 1), d, w], [Vector3(0, 0, -1), d, w], [Vector3(1, 0, 0), w, d], [Vector3(-1, 0, 0), w, d]]:
		var n: Vector3 = face[0]
		var depth: float = face[1]
		var span: float = face[2]
		var at := n * (depth * 0.5)
		var along := Vector3(n.z, 0, -n.x)  # across the face
		var rot := Vector3(0, 90 if absf(n.x) > 0.5 else 0, 0)
		for y: float in [t * 0.5, h - t * 0.5]:
			b.box(Vector3(span, t, 0.02), "wood_mid", at + Vector3(0, y, 0), rot)
		for s: float in [-1.0, 1.0]:
			b.box(Vector3(t, h, 0.02), "wood_mid", at + along * (s * (span * 0.5 - t * 0.5)) + Vector3(0, h * 0.5, 0), rot)
		var diag := sqrt(span * span + h * h) - t
		var ang := rad_to_deg(atan2(h, span))
		b.box(Vector3(diag, t * 0.9, 0.02), "wood_mid", at + Vector3(0, h * 0.5, 0), rot + Vector3(0, 0, ang))  # diagonal brace
	b.box(Vector3(w, 0.02, d), "crate_wood", Vector3(0, h + 0.01, 0))
	return h + 0.02


static func _pallet(b: Builder, w: float, d: float, rng: RandomNumberGenerator) -> float:
	for i in 3:
		b.box(Vector3(0.1, 0.1, d), "crate_wood", Vector3((i - 1) * (w * 0.5 - 0.05), 0.05, 0))
	for i in 7:
		b.box(Vector3(w, 0.022, 0.1), "crate_wood", Vector3(0, 0.111, -d * 0.5 + 0.05 + i * (d - 0.1) / 6.0))
	var y := 0.122
	for layer in 2:
		for ix in 2:
			for iz in 2:
				var bw := w * 0.5 - 0.02
				var bd := d * 0.5 - 0.02
				var bh := rng.randf_range(0.28, 0.34)
				b.box(Vector3(bw, bh, bd), "cardboard", Vector3((ix - 0.5) * w * 0.5, y + bh * 0.5, (iz - 0.5) * d * 0.5), Vector3(0, rng.randf_range(-3, 3), 0))
				b.box(Vector3(bw + 0.002, 0.004, 0.05), "tape", Vector3((ix - 0.5) * w * 0.5, y + bh + 0.002, (iz - 0.5) * d * 0.5))
		y += 0.34
		if layer == 0 and rng.randf() < 0.5:
			break
	return y


static func _workbench(b: Builder, w: float, d: float) -> float:
	var h := 0.9
	b.box(Vector3(w, 0.06, d), "wood_light", Vector3(0, h - 0.03, 0))
	_legs(b, w, d, h - 0.06, 0.06, "grey_metal", 0.05)
	b.box(Vector3(w - 0.1, 0.02, d - 0.1), "grey_metal", Vector3(0, 0.2, 0))
	b.box(Vector3(w, 0.75, 0.02), "cardboard", Vector3(0, h + 0.5, -d * 0.5 + 0.01))  # pegboard
	for i in 5:  # tools hanging on it
		var x := -w * 0.35 + i * w * 0.17
		b.box(Vector3(0.03, 0.2, 0.02), "red" if i % 2 == 0 else "black", Vector3(x, h + 0.55, -d * 0.5 + 0.03), Vector3(0, 0, (i - 2) * 10.0))
	b.box(Vector3(0.12, 0.1, 0.1), "blue", Vector3(w * 0.32, h + 0.05, 0.0))  # vise
	b.box(Vector3(0.4, 0.18, 0.2), "red", Vector3(-w * 0.2, h + 0.09, 0.02))  # toolbox
	b.box(Vector3(0.42, 0.02, 0.06), "black", Vector3(-w * 0.2, h + 0.19, 0.02))
	b.box(Vector3(0.25, 0.02, 0.04), "black", Vector3(0.05, h + 0.01, 0.12), Vector3(0, 25, 0))  # hammer
	return h + 0.88


static func _police_car(b: Builder, w: float, d: float, meta: Dictionary) -> float:
	# body along Z (front +Z), w wide
	var wheel := 0.33
	for sz: float in [-1.0, 1.0]:
		for sx: float in [-1.0, 1.0]:
			var at := Vector3(sx * (w * 0.5 - 0.13), wheel, sz * (d * 0.5 - 0.85))
			b.tube(wheel, 0.24, "rubber", at, Vector3(0, 0, 90), 18)
			b.tube(wheel * 0.6, 0.245, "steel", at, Vector3(0, 0, 90), 12)
	var hood := 1.15
	var trunk := 0.95
	var mid := d - hood - trunk
	b.box(Vector3(w, 0.6, hood), "car_black", Vector3(0, 0.6, d * 0.5 - hood * 0.5))
	b.box(Vector3(w, 0.6, mid), "car_white", Vector3(0, 0.6, d * 0.5 - hood - mid * 0.5))
	b.box(Vector3(w, 0.6, trunk), "car_black", Vector3(0, 0.6, -d * 0.5 + trunk * 0.5))
	b.box(Vector3(w - 0.1, 0.12, d - 0.1), "rubber", Vector3(0, 0.25, 0))  # sills
	for s: float in [-1.0, 1.0]:  # bumpers, push bar, lights
		b.box(Vector3(w + 0.02, 0.18, 0.1), "black", Vector3(0, 0.42, s * (d * 0.5 + 0.02)))
		for sx: float in [-1.0, 1.0]:
			b.box(Vector3(0.28, 0.1, 0.04), "headlight" if s > 0 else "taillight", Vector3(sx * (w * 0.5 - 0.22), 0.78, s * (d * 0.5 + 0.005)))
	b.box(Vector3(w * 0.8, 0.4, 0.06), "black", Vector3(0, 0.55, d * 0.5 + 0.1))
	b.box(Vector3(w * 0.4, 0.1, 0.03), "dark_grey", Vector3(0, 0.75, d * 0.5 + 0.012))  # grille
	# cabin: a glass frustum (a four-sided cone turned square and stretched) under a white roof
	var cab_len := mid + 0.55
	var cab_z := d * 0.5 - hood - mid * 0.5 + 0.05
	var glass := CylinderMesh.new()
	glass.bottom_radius = 0.5
	glass.top_radius = 0.36
	glass.height = 0.48
	glass.radial_segments = 4
	glass.rings = 1
	var half := 0.5 / sqrt(2.0)  # the square's half width before stretching
	b.add(glass, "glass", Transform3D(Basis.from_scale(Vector3((w - 0.12) * 0.5 / half, 1.0, cab_len * 0.5 / half)) * Basis(Vector3.UP, PI * 0.25),
			Vector3(0, 1.14, cab_z)))
	b.box(Vector3(w - 0.24, 0.05, cab_len - 0.6), "car_white", Vector3(0, 1.4, cab_z))
	for sx: float in [-1.0, 1.0]:  # mirrors
		b.box(Vector3(0.12, 0.08, 0.05), "car_black", Vector3(sx * (w * 0.5 + 0.05), 0.98, d * 0.5 - hood - 0.1))
	# light bar
	var bar_y := 1.47
	b.box(Vector3(w * 0.78, 0.04, 0.24), "black", Vector3(0, bar_y - 0.02, cab_z))
	b.box(Vector3(w * 0.36, 0.08, 0.2), "bar_red", Vector3(-w * 0.2, bar_y + 0.04, cab_z))
	b.box(Vector3(w * 0.36, 0.08, 0.2), "bar_blue", Vector3(w * 0.2, bar_y + 0.04, cab_z))
	meta["lights"] = [Vector3(-w * 0.2, bar_y + 0.15, cab_z), Vector3(w * 0.2, bar_y + 0.15, cab_z)]
	meta["light_mats"] = [mat("bar_red"), mat("bar_blue")]
	return 1.55


## [mesh, metadata] from assets/props/<set>/<kind>.glb scaled evenly to the footprint, [] without.
static func _from_file(kind: String, w: float, d: float) -> Array:
	var root := CharacterModels._load_glb(folder + set_name + "/" + kind + ".glb")
	if root == null:
		return []
	var parts := CharacterModels._mesh_transforms(root, Transform3D.IDENTITY)
	var box := AABB()
	var first := true
	for entry in parts:
		var mi: MeshInstance3D = entry[0]
		if mi.mesh != null:
			var bb: AABB = entry[1] * mi.mesh.get_aabb()
			box = bb if first else box.merge(bb)
			first = false
	if first or box.size.x <= 0.0001 or box.size.z <= 0.0001:
		root.free()
		return []
	var s := minf(w / box.size.x, d / box.size.z)
	var to := Transform3D(Basis.from_scale(Vector3.ONE * s), -Vector3(box.get_center().x, box.position.y, box.get_center().z) * s)
	var mesh := ArrayMesh.new()
	for entry in parts:
		var mi: MeshInstance3D = entry[0]
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var arr := CharacterModels._bake(mi.mesh.surface_get_arrays(i), to * (entry[1] as Transform3D))
			arr[Mesh.ARRAY_BONES] = null
			arr[Mesh.ARRAY_WEIGHTS] = null
			var prim := (mi.mesh as ArrayMesh).surface_get_primitive_type(i) if mi.mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
			mesh.add_surface_from_arrays(prim, arr)
			var m := mi.get_active_material(i)
			var bm := m as BaseMaterial3D
			if bm != null and bm.metallic_texture == null and bm.metallic > 0.9:
				bm.metallic = 0.7
			mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	root.free()
	var meta := {"h": box.size.y * s, "file": true}
	if kind == "police_car":  # the light bar on the roof, red left, blue right
		var h: float = meta["h"]
		meta["lights"] = [Vector3(-w * 0.2, h + 0.1, 0), Vector3(w * 0.2, h + 0.1, 0)]
		meta["light_mats"] = []
	return [mesh, meta]
