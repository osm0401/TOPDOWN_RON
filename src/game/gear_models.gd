extends RefCounted
## Gear the 3D view puts on the character models, built from boxes and cylinders (no asset files):
## the officers' rifles (rifle_lethal black, rifle_nonlethal with orange less-lethal furniture) and
## pistol, the suspects' pistol, handcuffs, the red cap and yellow armband clues, the door camera;
## and what people wear (ACCESSORIES): a beanie, glasses, sunglasses, a bandana over the face, a
## backpack, the officers' shoulder patch, radio, helmet camera and shoulder microphone. Kit with a
## small light ("led" point: the radio's channel light, the helmet camera's recording light) gets
## it as a child node "led" with its own material, so each officer's light blinks on its own
## (set_led). Beanie, bandana and glasses are built to a unit
## head (1 across) and scaled to each wearer (CharacterAnim); the view tints beanie, bandana,
## backpack and patch per person (material_override). (Hair is painted on: character.gdshader.)
## make() returns a MeshInstance3D whose local frame is: origin where the right hand grips, +Z out of
## the muzzle, +Y up. Its metadata holds the points CharacterAnim needs, in that frame: "fore" (where
## the support hand holds), "muzzle", "light" (weapon light lens) and "stock" (butt end, rifles).
## Each kind's mesh is built once (one surface per material) and shared.
## A model file replaces the built-in shape: assets/gear/<set>/<kind>.glb (set_name, from
## data/view3d.json characters.set). It is drawn in the same frame; empty nodes in it named after the
## points mark them ("grip" moves the origin there; "fore", "muzzle", "light", "stock", "mag"; a
## point the file does not mark keeps the built-in shape's). A file whose size is far off the
## built-in shape's (made in centimetres, say) is scaled to it. Guide: docs/09-3d-models-antigravity.md.
## No class_name: preloaded (see character_models.gd).

const CharacterModels := preload("res://src/game/character_models.gd")
const ACCESSORIES: Array[String] = ["beanie", "glasses", "sunglasses", "bandana", "backpack", "patch", "radio"]
const KINDS: Array[String] = ["rifle_lethal", "rifle_nonlethal", "pistol", "cuffs", "cap", "band", "camera",
	"beanie", "glasses", "sunglasses", "bandana", "backpack", "patch", "radio", "helmet_cam", "mic"]
const POINTS: Array[String] = ["fore", "muzzle", "light", "stock", "mag", "led"]
const DIR := "res://assets/gear/"

static var folder := DIR  ## where model files are looked for (tests point it elsewhere)
static var set_name := ""  ## subfolder of folder with the model files; "" = built-in shapes only
static var _meshes: Dictionary = {}  ## kind or "<set>/<kind>" -> [ArrayMesh, metadata]
static var _mats: Dictionary = {}


## A new node showing gear `kind` (one of KINDS); unknown kinds fall back to the pistol.
static func make(kind: String) -> MeshInstance3D:
	if not KINDS.has(kind):
		kind = "pistol"
	var key := kind if set_name == "" else set_name + "/" + kind
	if not _meshes.has(key):
		var built: Array = _from_file(folder + set_name + "/" + kind + ".glb", kind) if set_name != "" else []
		_meshes[key] = built if not built.is_empty() else _builtin(kind)
	var mi := MeshInstance3D.new()
	mi.name = kind
	mi.mesh = _meshes[key][0]
	var meta: Dictionary = _meshes[key][1]
	for k: String in meta:
		mi.set_meta(k, meta[k])
	if meta.has("led"):
		var led := MeshInstance3D.new()
		led.name = "led"
		var dot := SphereMesh.new()
		dot.radius = 0.0045
		dot.height = 0.009
		dot.radial_segments = 8
		dot.rings = 4
		led.mesh = dot
		var m := StandardMaterial3D.new()
		m.albedo_color = LED_OFF
		m.roughness = 0.3
		m.emission_enabled = true
		m.emission = Color.BLACK
		m.emission_energy_multiplier = 4.0
		led.material_override = m
		led.position = meta["led"]
		mi.add_child(led)
	return mi


const LED_OFF := Color(0.06, 0.05, 0.05)


## Lights gear `g`'s "led" child (made by make) in `color`; Color.BLACK turns it off.
static func set_led(g: Node, color: Color) -> void:
	var led := g.get_node_or_null("led") as MeshInstance3D
	if led == null:
		return
	var m := led.material_override as StandardMaterial3D
	m.emission = color
	m.albedo_color = LED_OFF if color == Color.BLACK else color


## True when gear `kind` comes from a model file (for the model check tool).
static func from_file(kind: String) -> bool:
	make(kind).free()
	return set_name != "" and _meshes[set_name + "/" + kind] != _builtin(kind)


## Drops the shared meshes (at quit, like CharacterModels.release()).
static func release() -> void:
	_meshes.clear()
	_mats.clear()


static func _builtin(kind: String) -> Array:
	if not _meshes.has(kind):
		_meshes[kind] = _build(kind)
	return _meshes[kind]


## [mesh, metadata] from a .glb drawn in the gear frame, or [] when the file is missing or empty.
## All meshes are merged into one (each surface keeps its material).
static func _from_file(path: String, kind: String) -> Array:
	var root := CharacterModels._load_glb(path)
	if root == null:
		return []
	var marks := {}
	_find_points(root, Transform3D.IDENTITY, marks)
	var parts := CharacterModels._mesh_transforms(root, Transform3D.IDENTITY)
	var box := AABB()
	var first := true
	for entry in parts:
		var mi: MeshInstance3D = entry[0]
		if mi.mesh != null:
			var b: AABB = entry[1] * mi.mesh.get_aabb()
			box = b if first else box.merge(b)
			first = false
	if first:
		push_warning("gear model %s has no mesh" % path)
		root.free()
		return []
	var grip: Vector3 = marks.get("grip", Vector3.ZERO)
	var want := (_builtin(kind)[0] as ArrayMesh).get_aabb().get_longest_axis_size()
	var s := 1.0
	var size := box.get_longest_axis_size()
	if size > 0.0001 and (size > want * 2.0 or size < want * 0.5):
		s = want / size
		push_warning("gear model %s is %.3f long, scaled x%.3f to the built-in %.3f (meters?)" % [path, size, s, want])
	var to_gear := Transform3D(Basis.from_scale(Vector3.ONE * s), -grip * s)
	var mesh := ArrayMesh.new()
	for entry in parts:
		var mi: MeshInstance3D = entry[0]
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var arr := CharacterModels._bake(mi.mesh.surface_get_arrays(i), to_gear * (entry[1] as Transform3D))
			arr[Mesh.ARRAY_BONES] = null  # drawn rigid on the hand / body, never skinned
			arr[Mesh.ARRAY_WEIGHTS] = null
			var prim := (mi.mesh as ArrayMesh).surface_get_primitive_type(i) if mi.mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
			mesh.add_surface_from_arrays(prim, arr)
			var mat := mi.get_active_material(i)
			var bm := mat as BaseMaterial3D
			if bm != null and bm.metallic_texture == null and bm.metallic > 0.9:
				bm.metallic = 0.7  # full metal turns black here: the scene has no sky to reflect
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	root.free()
	var meta: Dictionary = (_builtin(kind)[1] as Dictionary).duplicate()
	for p: String in POINTS:
		if marks.has(p):
			meta[p] = to_gear * (marks[p] as Vector3)
	print("[gear] %s: %s, points %s" % [path.get_file(), (to_gear * box).size, ", ".join(PackedStringArray(marks.keys()))])
	return [mesh, meta]


## Positions of the marker nodes under `node` into marks: point name -> position in the file's
## space. A marker is an empty node (not a mesh, so a part named "light" is not taken for the
## point) named after the point, compared in lower case; a "point_" / "marker_" prefix and a
## ".001" / "_001" suffix are ignored.
static func _find_points(node: Node, xf: Transform3D, marks: Dictionary) -> void:
	for c in node.get_children():
		var cx := xf * (c as Node3D).transform if c is Node3D else xf
		var nm := String(c.name).to_lower().get_slice(".", 0)
		if nm.get_slice("_", nm.get_slice_count("_") - 1).is_valid_int():
			nm = nm.substr(0, nm.rfind("_"))
		for prefix: String in ["point_", "marker_"]:
			nm = nm.trim_prefix(prefix)
		if c is Node3D and not c is VisualInstance3D and (nm == "grip" or POINTS.has(nm)) and not marks.has(nm):
			marks[nm] = cx.origin
		_find_points(c, cx, marks)


static func _mat(key: String) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	match key:
		"polymer":
			m.albedo_color = Color(0.07, 0.07, 0.075)
			m.roughness = 0.7
		"metal":
			m.albedo_color = Color(0.14, 0.14, 0.15)
			m.metallic = 0.7
			m.roughness = 0.4
		"steel":
			m.albedo_color = Color(0.62, 0.63, 0.66)
			m.metallic = 0.9
			m.roughness = 0.28
		"orange":  # less-lethal furniture: tells the non-lethal launcher apart at a glance
			m.albedo_color = Color(0.95, 0.42, 0.06)
			m.roughness = 0.55
		"lens":
			m.albedo_color = Color(0.9, 0.95, 1.0)
			m.emission_enabled = true
			m.emission = Color(0.8, 0.85, 1.0)
			m.emission_energy_multiplier = 0.6
		"glass":
			m.albedo_color = Color(0.1, 0.25, 0.3)
			m.metallic = 0.3
			m.roughness = 0.1
		"red":
			m.albedo_color = Color(0.85, 0.08, 0.07)
			m.roughness = 0.8
		"dark_red":
			m.albedo_color = Color(0.45, 0.04, 0.04)
			m.roughness = 0.85
		"yellow":  # armband: a clue, so it glows a little to stay readable in the dark
			m.albedo_color = Color(1.0, 0.85, 0.15)
			m.roughness = 0.8
			m.emission_enabled = true
			m.emission = Color(1.0, 0.8, 0.1)
			m.emission_energy_multiplier = 0.25
		"cloth":  # tinted per person (material_override); this is the colour without one
			m.albedo_color = Color(0.2, 0.2, 0.22)
			m.roughness = 0.95
		"frame":
			m.albedo_color = Color(0.05, 0.05, 0.05)
			m.roughness = 0.35
		"clear_lens":
			m.albedo_color = Color(0.85, 0.9, 0.95, 0.25)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.05
		"dark_lens":
			m.albedo_color = Color(0.03, 0.03, 0.04)
			m.metallic = 0.5
			m.roughness = 0.08
		"strap":
			m.albedo_color = Color(0.06, 0.06, 0.07)
			m.roughness = 0.9
		"screen":
			m.albedo_color = Color(0.1, 0.3, 0.25)
			m.emission_enabled = true
			m.emission = Color(0.2, 0.7, 0.5)
			m.emission_energy_multiplier = 0.8
	_mats[key] = m
	return m


## Collects primitive parts per material and merges them into one ArrayMesh.
class Builder:
	var tools: Dictionary = {}  ## material key -> SurfaceTool

	func add(mesh: PrimitiveMesh, mat: String, at: Vector3, rot_deg := Vector3.ZERO) -> void:
		if not tools.has(mat):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[mat] = st
		var b := Basis.from_euler(rot_deg * (PI / 180.0))
		(tools[mat] as SurfaceTool).append_from(mesh, 0, Transform3D(b, at))

	func box(size: Vector3, mat: String, at: Vector3, rot_deg := Vector3.ZERO) -> void:
		var m := BoxMesh.new()
		m.size = size
		add(m, mat, at, rot_deg)

	## A cylinder along +Z (rot_deg turns it further).
	func tube(radius: float, length: float, mat: String, at: Vector3, rot_deg := Vector3(90, 0, 0), sides := 12) -> void:
		var m := CylinderMesh.new()
		m.top_radius = radius
		m.bottom_radius = radius
		m.height = length
		m.radial_segments = sides
		m.rings = 1
		add(m, mat, at, rot_deg)

	## A band round the Y axis from from_deg to to_deg (0 = +Z, the face), open, both sides drawn:
	## the part of a bandana or a hat brim that wraps a head.
	func arc(radius: float, top: float, bottom: float, from_deg: float, to_deg: float, mat: String, at := Vector3.ZERO, steps := 14, depth := -1.0) -> void:
		var rz := radius if depth < 0.0 else depth  # an oval: radius across (x), depth front to back (z)
		var key := mat + "#arc"  # its own surface: hand-made vertices do not mix with appended shapes
		if not tools.has(key):
			var st0 := SurfaceTool.new()
			st0.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[key] = st0
		var st: SurfaceTool = tools[key]
		for i in steps:
			var a0 := deg_to_rad(lerpf(from_deg, to_deg, float(i) / steps))
			var a1 := deg_to_rad(lerpf(from_deg, to_deg, float(i + 1) / steps))
			var p: Array[Vector3] = [Vector3(sin(a0) * radius, top, cos(a0) * rz), Vector3(sin(a1) * radius, top, cos(a1) * rz),
					Vector3(sin(a1) * radius, bottom, cos(a1) * rz), Vector3(sin(a0) * radius, bottom, cos(a0) * rz)]
			var nrm: Array[Vector3] = [Vector3(sin(a0), 0, cos(a0)), Vector3(sin(a1), 0, cos(a1)), Vector3(sin(a1), 0, cos(a1)), Vector3(sin(a0), 0, cos(a0))]
			var uv: Array[Vector2] = [Vector2(float(i) / steps, 0), Vector2(float(i + 1) / steps, 0), Vector2(float(i + 1) / steps, 1), Vector2(float(i) / steps, 1)]
			for idx in [0, 1, 2, 0, 2, 3]:  # outside
				st.set_normal(nrm[idx])
				st.set_uv(uv[idx])
				st.add_vertex(at + p[idx])
			for idx in [0, 2, 1, 0, 3, 2]:  # inside
				st.set_normal(-nrm[idx])
				st.set_uv(uv[idx])
				st.add_vertex(at + p[idx])

	## One surface per material key, in the order of `tools`.
	func commit() -> ArrayMesh:
		var out := ArrayMesh.new()
		for mat: String in tools:
			(tools[mat] as SurfaceTool).commit(out)
		return out


static func _build(kind: String) -> Array:
	var b := Builder.new()
	var meta := {}
	match kind:
		"rifle_lethal":  # AR-pattern carbine with an optic and a weapon light
			b.box(Vector3(0.05, 0.075, 0.27), "metal", Vector3(0, 0.055, 0.06))  # receiver
			b.box(Vector3(0.056, 0.058, 0.3), "polymer", Vector3(0, 0.07, 0.34))  # handguard
			b.tube(0.011, 0.16, "metal", Vector3(0, 0.07, 0.56))  # barrel
			b.tube(0.017, 0.045, "metal", Vector3(0, 0.07, 0.655))  # muzzle device
			b.tube(0.017, 0.16, "polymer", Vector3(0, 0.07, -0.14))  # buffer tube
			b.box(Vector3(0.045, 0.1, 0.13), "polymer", Vector3(0, 0.05, -0.24))  # stock
			b.box(Vector3(0.034, 0.1, 0.042), "polymer", Vector3(0, -0.025, 0.0), Vector3(-18, 0, 0))  # pistol grip
			b.box(Vector3(0.028, 0.15, 0.07), "metal", Vector3(0, -0.04, 0.11), Vector3(12, 0, 0))  # magazine
			b.box(Vector3(0.012, 0.03, 0.045), "polymer", Vector3(0, 0.0, 0.04))  # trigger guard
			b.box(Vector3(0.034, 0.045, 0.1), "polymer", Vector3(0, 0.12, 0.07))  # optic body
			b.box(Vector3(0.03, 0.035, 0.006), "glass", Vector3(0, 0.122, 0.121))  # optic lens
			b.tube(0.016, 0.09, "polymer", Vector3(0.042, 0.07, 0.42))  # weapon light
			b.tube(0.013, 0.004, "lens", Vector3(0.042, 0.07, 0.467))
			meta = {"fore": Vector3(0.0, 0.035, 0.29), "muzzle": Vector3(0, 0.07, 0.68), "light": Vector3(0.042, 0.07, 0.47), "stock": Vector3(0, 0.06, -0.3),
					"mag": Vector3(0, -0.07, 0.11)}
		"rifle_nonlethal":  # less-lethal launcher: pump gun with orange stock and forend
			b.box(Vector3(0.05, 0.07, 0.24), "metal", Vector3(0, 0.05, 0.05))  # receiver
			b.tube(0.016, 0.42, "metal", Vector3(0, 0.07, 0.38))  # barrel
			b.tube(0.013, 0.34, "metal", Vector3(0, 0.035, 0.33))  # magazine tube
			b.box(Vector3(0.05, 0.05, 0.16), "orange", Vector3(0, 0.035, 0.33))  # pump forend
			b.box(Vector3(0.042, 0.12, 0.26), "orange", Vector3(0, 0.03, -0.2), Vector3(-8, 0, 0))  # stock
			b.box(Vector3(0.012, 0.03, 0.045), "polymer", Vector3(0, -0.005, 0.03))  # trigger guard
			b.tube(0.016, 0.08, "polymer", Vector3(0.04, 0.07, 0.36))  # weapon light
			b.tube(0.013, 0.004, "lens", Vector3(0.04, 0.07, 0.402))
			meta = {"fore": Vector3(0.0, 0.01, 0.3), "muzzle": Vector3(0, 0.07, 0.6), "light": Vector3(0.04, 0.07, 0.405), "stock": Vector3(0, 0.03, -0.33),
					"mag": Vector3(0, 0.0, 0.08)}
		"pistol":  # polymer striker pistol: slide with serrations, ejection port and sights, railed frame with a light
			b.box(Vector3(0.03, 0.032, 0.19), "metal", Vector3(0, 0.05, 0.06))  # slide
			for k in 5:  # rear serrations
				b.box(Vector3(0.032, 0.026, 0.003), "polymer", Vector3(0, 0.051, -0.02 + k * 0.007))
			b.box(Vector3(0.002, 0.012, 0.04), "polymer", Vector3(0.0155, 0.055, 0.075))  # ejection port
			b.box(Vector3(0.006, 0.008, 0.008), "polymer", Vector3(0, 0.07, 0.145))  # front sight
			b.box(Vector3(0.018, 0.008, 0.008), "polymer", Vector3(0, 0.07, -0.025))  # rear sight
			b.tube(0.0055, 0.004, "polymer", Vector3(0, 0.05, 0.156))  # muzzle
			b.box(Vector3(0.028, 0.024, 0.15), "polymer", Vector3(0, 0.022, 0.05))  # frame
			b.box(Vector3(0.024, 0.006, 0.05), "polymer", Vector3(0, 0.008, 0.1))  # accessory rail
			b.box(Vector3(0.03, 0.105, 0.05), "polymer", Vector3(0, -0.026, -0.006), Vector3(-18, 0, 0))  # grip
			b.box(Vector3(0.031, 0.06, 0.03), "metal", Vector3(0, -0.03, -0.012), Vector3(-18, 0, 0))  # grip texture panel
			b.box(Vector3(0.032, 0.008, 0.052), "polymer", Vector3(0, -0.079, -0.024), Vector3(-18, 0, 0))  # magazine base plate
			b.box(Vector3(0.008, 0.028, 0.004), "polymer", Vector3(0, 0.0, 0.055))  # trigger guard front
			b.box(Vector3(0.008, 0.004, 0.04), "polymer", Vector3(0, -0.013, 0.035))  # trigger guard bottom
			b.box(Vector3(0.005, 0.018, 0.006), "metal", Vector3(0, 0.0, 0.028), Vector3(15, 0, 0))  # trigger
			b.box(Vector3(0.03, 0.028, 0.065), "polymer", Vector3(0, -0.002, 0.11))  # light
			b.box(Vector3(0.024, 0.02, 0.004), "lens", Vector3(0, -0.002, 0.144))
			meta = {"fore": Vector3(0.022, -0.012, 0.0), "muzzle": Vector3(0, 0.05, 0.158), "light": Vector3(0, 0.0, 0.146), "mag": Vector3(0, -0.08, -0.02)}
		"cuffs":  # two rings side by side along X, chained
			for x: float in [-0.045, 0.045]:
				var ring := TorusMesh.new()
				ring.inner_radius = 0.028
				ring.outer_radius = 0.037
				ring.rings = 16
				ring.ring_segments = 6
				b.add(ring, "steel", Vector3(x, 0, 0), Vector3(0, 0, 90))
			b.box(Vector3(0.03, 0.008, 0.008), "steel", Vector3.ZERO)
		"cap":  # baseball cap: six-panel dome with seams, a button and eyelets, a curved brim toward +Z (the face)
			var dome := SphereMesh.new()
			dome.radius = 0.105
			dome.height = 0.105
			dome.is_hemisphere = true
			dome.radial_segments = 20
			dome.rings = 7
			b.add(dome, "red", Vector3.ZERO)
			for k in 3:  # panel seams over the crown
				b.box(Vector3(0.004, 0.003, 0.2), "dark_red", Vector3(0, 0.07, 0), Vector3(-0.0, k * 60.0, 0))
			for k in 6:  # sewn eyelets
				var a := deg_to_rad(30.0 + k * 60.0)
				b.tube(0.005, 0.004, "dark_red", Vector3(sin(a) * 0.07, 0.07, cos(a) * 0.07), Vector3(0, 0, 0), 8)
			b.tube(0.012, 0.012, "red", Vector3(0, 0.105, 0), Vector3.ZERO, 8)  # button
			for k in 5:  # the brim, in slats that curve down at the sides
				var x := (k - 2) * 0.034
				b.box(Vector3(0.036, 0.008, 0.1), "red", Vector3(x, 0.004 - absf(x) * 0.18, 0.135 - absf(x) * 0.12), Vector3(-8, -x * 160.0, -x * 220.0))
			b.box(Vector3(0.16, 0.012, 0.012), "dark_red", Vector3(0, 0.006, 0.09))  # sweatband edge over the brim
		"band":  # open sleeve around an arm, axis along Y
			var sleeve := CylinderMesh.new()
			sleeve.top_radius = 0.066
			sleeve.bottom_radius = 0.066
			sleeve.height = 0.09
			sleeve.radial_segments = 16
			sleeve.rings = 1
			sleeve.cap_top = false
			sleeve.cap_bottom = false
			b.add(sleeve, "yellow", Vector3.ZERO)
		"beanie":  # knit cap pulled over the crown, with a folded cuff
			var dome := SphereMesh.new()
			dome.radius = 0.55
			dome.height = 0.72  # a dome 0.36 tall, just over the crown
			dome.is_hemisphere = true
			dome.radial_segments = 20
			dome.rings = 8
			b.add(dome, "cloth", Vector3(0, 0.17, -0.03), Vector3(-12, 0, 0))
			var cuff := CylinderMesh.new()  # the fold across the forehead
			cuff.top_radius = 0.56
			cuff.bottom_radius = 0.57
			cuff.height = 0.13
			cuff.radial_segments = 20
			cuff.rings = 1
			b.add(cuff, "cloth", Vector3(0, 0.2, -0.03), Vector3(-12, 0, 0))
		"glasses", "sunglasses":  # two lenses, a bridge and the arms back to the ears (unit head)
			var lens := "dark_lens" if kind == "sunglasses" else "clear_lens"
			for x: float in [-0.21, 0.21]:
				var rim := TorusMesh.new()
				rim.inner_radius = 0.105 if kind == "glasses" else 0.12
				rim.outer_radius = 0.125 if kind == "glasses" else 0.14
				rim.rings = 16
				rim.ring_segments = 4
				b.add(rim, "frame", Vector3(x, 0, 0), Vector3(90, 0, 0))
				var glass := CylinderMesh.new()
				glass.top_radius = rim.inner_radius
				glass.bottom_radius = rim.inner_radius
				glass.height = 0.01
				glass.radial_segments = 16
				glass.rings = 1
				b.add(glass, lens, Vector3(x, 0, 0), Vector3(90, 0, 0))
				b.box(Vector3(0.02, 0.025, 0.55), "frame", Vector3(x * 2.25, 0.02, -0.27))  # arm to the ear
			b.box(Vector3(0.18, 0.025, 0.02), "frame", Vector3(0, 0.03, 0))  # bridge
		"bandana":  # cloth over the nose and mouth, round the front of a unit head, a point under the chin
			b.arc(0.47, 0.0, -0.36, -118.0, 118.0, "cloth", Vector3.ZERO, 18, 0.6)  # over the nose, clear of the lips and beard
			b.arc(0.42, -0.36, -0.46, -60.0, 60.0, "cloth", Vector3(0, 0, 0.02), 10, 0.5)  # the loose fold under the chin
		"backpack":  # a small daypack (meters): body, front pocket, top handle, straps up over the shoulders
			b.box(Vector3(0.3, 0.4, 0.13), "cloth", Vector3(0, 0, -0.065))
			b.box(Vector3(0.24, 0.17, 0.05), "cloth", Vector3(0, -0.08, -0.15))
			b.box(Vector3(0.26, 0.02, 0.012), "strap", Vector3(0, 0.0, -0.176))  # pocket zip
			b.tube(0.01, 0.08, "strap", Vector3(0, 0.205, -0.06), Vector3(0, 0, 90))
			for x: float in [-0.08, 0.08]:
				b.box(Vector3(0.045, 0.02, 0.16), "strap", Vector3(x, 0.205, 0.05), Vector3(-20, 0, 0))  # over the shoulder
		"patch":  # shoulder patch in the officer's player colour, with a light rim
			b.box(Vector3(0.07, 0.08, 0.006), "cloth", Vector3.ZERO)
			b.box(Vector3(0.078, 0.088, 0.003), "steel", Vector3(0, 0, -0.002))
		"radio":  # chest radio: body, display, push-to-talk, channel knob, antenna, a channel light on top
			b.box(Vector3(0.055, 0.1, 0.03), "polymer", Vector3(0, 0, 0))
			b.box(Vector3(0.042, 0.022, 0.003), "screen", Vector3(0.0, 0.028, 0.0155))
			b.box(Vector3(0.02, 0.03, 0.012), "polymer", Vector3(0.0, -0.02, 0.02))
			b.box(Vector3(0.057, 0.012, 0.032), "metal", Vector3(0.0, -0.036, 0.0))  # belt clip band
			b.tube(0.0065, 0.014, "metal", Vector3(-0.014, 0.057, 0.0), Vector3.ZERO, 10)  # channel knob
			b.tube(0.004, 0.13, "polymer", Vector3(0.015, 0.11, 0), Vector3.ZERO, 6)
			b.tube(0.007, 0.015, "polymer", Vector3(0.015, 0.18, 0), Vector3.ZERO, 6)
			meta = {"led": Vector3(0.002, 0.052, 0.006)}
		"helmet_cam":  # helmet camera on the side rail: origin on the helmet, the camera out to -X, lens to +Z
			b.box(Vector3(0.008, 0.026, 0.055), "polymer", Vector3(-0.004, 0.0, 0.0))  # rail mount
			b.box(Vector3(0.028, 0.03, 0.07), "polymer", Vector3(-0.022, 0.0, 0.006))  # body
			b.tube(0.011, 0.012, "metal", Vector3(-0.022, 0.0, 0.045))  # lens barrel
			b.tube(0.008, 0.003, "glass", Vector3(-0.022, 0.0, 0.052))
			b.box(Vector3(0.01, 0.006, 0.012), "metal", Vector3(-0.022, 0.017, -0.014))  # record button
			meta = {"led": Vector3(-0.022, 0.016, 0.028)}
		"mic":  # speaker-microphone clipped to the vest strap: origin on the strap, out to +Z, cable down
			b.box(Vector3(0.042, 0.058, 0.024), "polymer", Vector3(0.0, 0.0, 0.012))
			b.box(Vector3(0.032, 0.026, 0.003), "metal", Vector3(0.0, 0.008, 0.0245))  # speaker grille
			b.box(Vector3(0.012, 0.02, 0.008), "polymer", Vector3(0.024, -0.004, 0.012))  # talk button
			b.tube(0.0035, 0.09, "strap", Vector3(-0.012, -0.07, 0.006), Vector3.ZERO, 6)  # coiled cable to the radio
		"camera":  # door camera: handle, screen, probe forward
			b.box(Vector3(0.035, 0.11, 0.04), "polymer", Vector3(0, -0.02, 0.0))
			b.box(Vector3(0.1, 0.07, 0.02), "polymer", Vector3(0, 0.07, 0.01), Vector3(-30, 0, 0))
			b.box(Vector3(0.088, 0.058, 0.004), "screen", Vector3(0, 0.073, 0.0), Vector3(-30, 0, 0))
			b.tube(0.006, 0.35, "metal", Vector3(0, 0.02, 0.2))
			b.box(Vector3(0.022, 0.022, 0.03), "polymer", Vector3(0, 0.02, 0.385))
			meta = {"fore": Vector3(0.0, 0.05, 0.06)}
	var mesh := b.commit()
	var i := 0
	for key: String in b.tools:
		mesh.surface_set_material(i, _mat(key.get_slice("#", 0)))
		i += 1
	return [mesh, meta]
