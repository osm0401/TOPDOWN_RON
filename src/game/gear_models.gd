extends RefCounted
## Gear the 3D view puts on the character models, built from boxes and cylinders (no asset files):
## the officers' rifles (rifle_lethal black, rifle_nonlethal with orange less-lethal furniture) and
## pistol, the suspects' pistol, handcuffs, the red cap and yellow armband clues, the door camera.
## make() returns a MeshInstance3D whose local frame is: origin where the right hand grips, +Z out of
## the muzzle, +Y up. Its metadata holds the points CharacterAnim needs, in that frame: "fore" (where
## the support hand holds), "muzzle", "light" (weapon light lens) and "stock" (butt end, rifles).
## Each kind's mesh is built once (one surface per material) and shared.
## No class_name: preloaded (see character_models.gd).

const KINDS: Array[String] = ["rifle_lethal", "rifle_nonlethal", "pistol", "cuffs", "cap", "band", "camera"]

static var _meshes: Dictionary = {}  ## kind -> [ArrayMesh, metadata]
static var _mats: Dictionary = {}


## A new node showing gear `kind` (one of KINDS); unknown kinds fall back to the pistol.
static func make(kind: String) -> MeshInstance3D:
	if not KINDS.has(kind):
		kind = "pistol"
	if not _meshes.has(kind):
		_meshes[kind] = _build(kind)
	var mi := MeshInstance3D.new()
	mi.name = kind
	mi.mesh = _meshes[kind][0]
	var meta: Dictionary = _meshes[kind][1]
	for k: String in meta:
		mi.set_meta(k, meta[k])
	return mi


## Drops the shared meshes (at quit, like CharacterModels.release()).
static func release() -> void:
	_meshes.clear()
	_mats.clear()


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
		"yellow":  # armband: a clue, so it glows a little to stay readable in the dark
			m.albedo_color = Color(1.0, 0.85, 0.15)
			m.roughness = 0.8
			m.emission_enabled = true
			m.emission = Color(1.0, 0.8, 0.1)
			m.emission_energy_multiplier = 0.25
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
		"pistol":  # polymer striker pistol with an underbarrel light
			b.box(Vector3(0.03, 0.033, 0.19), "metal", Vector3(0, 0.05, 0.06))  # slide
			b.box(Vector3(0.028, 0.025, 0.15), "polymer", Vector3(0, 0.022, 0.05))  # frame
			b.box(Vector3(0.03, 0.11, 0.05), "polymer", Vector3(0, -0.025, -0.005), Vector3(-18, 0, 0))  # grip
			b.box(Vector3(0.01, 0.028, 0.04), "polymer", Vector3(0, 0.0, 0.035))  # trigger guard
			b.box(Vector3(0.03, 0.028, 0.065), "polymer", Vector3(0, 0.0, 0.11))  # light
			b.box(Vector3(0.024, 0.02, 0.004), "lens", Vector3(0, 0.0, 0.144))
			meta = {"fore": Vector3(0.022, -0.012, 0.0), "muzzle": Vector3(0, 0.05, 0.156), "light": Vector3(0, 0.0, 0.146), "mag": Vector3(0, -0.08, -0.02)}
		"cuffs":  # two rings side by side along X, chained
			for x: float in [-0.045, 0.045]:
				var ring := TorusMesh.new()
				ring.inner_radius = 0.028
				ring.outer_radius = 0.037
				ring.rings = 16
				ring.ring_segments = 6
				b.add(ring, "steel", Vector3(x, 0, 0), Vector3(0, 0, 90))
			b.box(Vector3(0.03, 0.008, 0.008), "steel", Vector3.ZERO)
		"cap":  # baseball cap: dome on the head, brim toward +Z (the face)
			var dome := SphereMesh.new()
			dome.radius = 0.105
			dome.height = 0.105
			dome.is_hemisphere = true
			dome.radial_segments = 16
			dome.rings = 6
			b.add(dome, "red", Vector3.ZERO)
			b.box(Vector3(0.17, 0.012, 0.1), "red", Vector3(0, 0.004, 0.13), Vector3(-6, 0, 0))
			b.tube(0.012, 0.012, "red", Vector3(0, 0.105, 0), Vector3.ZERO, 8)  # button
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
		mesh.surface_set_material(i, _mat(key))
		i += 1
	return [mesh, meta]
