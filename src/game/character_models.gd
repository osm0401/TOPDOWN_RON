extends RefCounted
## Character models for the 3D view: assets/characters/<name>.glb (officer, enemy, civilian and the
## hands-up enemy_up / civilian_up). Any model works: it is scaled to the figure height, stood on the
## floor at the origin and turned to face +X (the rig's aim; data/view3d.json "characters" yaw_deg
## fixes a model that faces elsewhere). No file: WorldView3D keeps its primitive figure.
## Loaded once per process; every figure gets its own copy (meshes are shared).
## Walking: the models come without bones, so each one is rigged when it loads (_rig guesses hips,
## knees and shoulders from the shape and skins the mesh to them) and pose_walk() swings the legs
## and arms. A model that already has a skeleton is shown as it is, without walking.
## No class_name on purpose: users preload this file. A new global class name is only known after
## the editor has rescanned the project, so a game started straight after git pull (no editor)
## failed to compile every script that named it.

const DIR := "res://assets/characters/"
## Bones of the auto-rig, in Skeleton3D order. The model faces +Z, so its left side is +X.
enum Bone { HIPS, SPINE, THIGH_L, SHIN_L, THIGH_R, SHIN_R, ARM_L, ARM_R }
const BONE_NAMES: Array[String] = ["hips", "spine", "thigh_l", "shin_l", "thigh_r", "shin_r", "arm_l", "arm_r"]
const BONE_PARENTS: Array[int] = [-1, Bone.HIPS, Bone.HIPS, Bone.THIGH_L, Bone.HIPS, Bone.THIGH_R, Bone.SPINE, Bone.SPINE]
const FLOOD_LOW := 0.36  ## share of the height no hand reaches down to: a flood from the wrist below it ran into a leg
const FUSE_BLEND := 0.03  ## share of the height a hand joined to the thigh blends over, along the surface
const FUSED_EDGES := 8  ## edges joining a hand to the thigh before the arms swing less (characters.walk.fused_arm)

static var folder := DIR  ## where make() looks (tests point it elsewhere)
static var _templates: Dictionary = {}  ## file path -> normalized model as a PackedScene, or null when missing / unreadable


## A fresh copy of model `name`: {"node": Node3D, "overlay": StandardMaterial3D, "lie_y": float,
## "skeleton": Skeleton3D or null} (overlay tints every surface; lie_y lifts the figure when it lies on
## its back; skeleton is the auto-rig pose_walk() moves). {} without a file.
## A hands-up model (<kind>_up) is fitted to up_height_m, fingertips included, so the body keeps the
## size of the standing model; only its legs are rigged.
static func make(name: String, cfg: Dictionary, dir := "") -> Dictionary:
	var path := (dir if dir != "" else folder) + name + ".glb"
	if not _templates.has(path):
		var body_h := float(cfg.get("height_m", 1.7))
		var up := name.ends_with("_up")
		var height := float(cfg.get("up_height_m", 2.05)) if up else body_h
		_templates[path] = _load_normalized(path, height, float(cfg.get("yaw_deg", 90.0)), body_h, not up)
	var tpl: PackedScene = _templates[path]
	if tpl == null:
		return {}
	var node := tpl.instantiate() as Node3D
	var overlay := StandardMaterial3D.new()
	overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # a tint still reads in a dark room
	overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	overlay.albedo_color = Color(1, 1, 1, 0)
	for mi in meshes(node):
		mi.material_overlay = overlay
	return {"node": node, "overlay": overlay, "lie_y": float(node.get_meta("lie_y", 0.15)),
			"skeleton": node.get_node_or_null("skeleton") as Skeleton3D}


## Poses a rigged model mid-stride. phase: radians along the stride (one cycle = two steps);
## amount: 0 standing .. 1 full stride; speed: m/s (faster = longer, more bent strides, more lean);
## dir: unit walking direction in the model's own space (+Z its front), so strafing and backing up
## step the right way. gait: data/view3d.json characters.walk. No skeleton: nothing happens.
static func pose_walk(model: Dictionary, phase: float, amount: float, speed: float, dir: Vector3, gait: Dictionary) -> void:
	var sk := model.get("skeleton") as Skeleton3D
	if sk == null:
		return
	if amount <= 0.001:
		if model.get("posed", false):
			sk.reset_bone_poses()
			model["posed"] = false
		return
	model["posed"] = true
	if dir.length_squared() < 0.5:
		dir = Vector3.BACK
	var run := clampf(inverse_lerp(float(gait["walk_mps"]), float(gait["run_mps"]), speed), 0.0, 1.0)
	var thigh := _gait(gait, "thigh_deg", run) * amount * sin(phase)
	var knee := _gait(gait, "knee_deg", run) * amount
	var stance := deg_to_rad(float(gait["stance_knee_deg"])) * amount
	var c := cos(phase)
	var swing := Vector3(-dir.z, 0.0, dir.x)  # turning about this axis moves a hanging limb toward dir
	sk.set_bone_pose_rotation(Bone.THIGH_L, Quaternion(swing, thigh))
	sk.set_bone_pose_rotation(Bone.THIGH_R, Quaternion(swing, -thigh))
	# the knee bends most while that leg swings through (about +X a hanging shin goes back)
	sk.set_bone_pose_rotation(Bone.SHIN_L, Quaternion(Vector3.RIGHT, stance + knee * maxf(c, 0.0)))
	sk.set_bone_pose_rotation(Bone.SHIN_R, Quaternion(Vector3.RIGHT, stance + knee * maxf(-c, 0.0)))
	# hips drop as the legs spread, so the planted foot stays on the floor
	var drop := float(sk.get_meta("leg_len", 0.9)) * (1.0 - cos(thigh)) * float(gait["hip_drop"])
	sk.set_bone_pose_position(Bone.HIPS, sk.get_bone_rest(Bone.HIPS).origin - Vector3(0.0, drop, 0.0))
	# arms and shoulders swing against the legs, only for the forward/backward part of the step
	var fwd := dir.z * amount * sin(phase)
	var lean := _gait(gait, "lean_deg", run) * amount
	sk.set_bone_pose_rotation(Bone.SPINE, Quaternion(Vector3.UP, _gait(gait, "twist_deg", run) * fwd) * Quaternion(swing, -lean))
	var arm := _gait(gait, "arm_deg", run) * fwd
	if sk.get_meta("fused_hand", false):  # a hand joined to the thigh stretches the join as it swings
		arm *= float(gait.get("fused_arm", 1.0))
	sk.set_bone_pose_rotation(Bone.ARM_L, Quaternion(Vector3.RIGHT, arm))
	sk.set_bone_pose_rotation(Bone.ARM_R, Quaternion(Vector3.RIGHT, -arm))


## Angle (radians) for gait[key] = [walking, running] degrees at run 0..1.
static func _gait(gait: Dictionary, key: String, run: float) -> float:
	var a: Array = gait[key]
	return deg_to_rad(lerpf(float(a[0]), float(a[1]), run))


## Drops the loaded models. Called when the game quits: a cached model still holding meshes when
## the renderer shuts down is reported as leaked.
static func release() -> void:
	_templates.clear()


static func meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for c in root.get_children():
		out.append_array(meshes(c))
	return out


## Bounds of every mesh under `root`, in root's parent space (works outside the scene tree).
static func bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for entry in _mesh_transforms(root, root.transform):
		var mi: MeshInstance3D = entry[0]
		if mi.mesh == null:
			continue
		var b: AABB = entry[1] * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


static func _mesh_transforms(node: Node, xf: Transform3D) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append([node, xf])
	for c in node.get_children():
		out.append_array(_mesh_transforms(c, xf * c.transform if c is Node3D else xf))
	return out


## Imported scene when the editor has imported the file, else read straight from the .glb (a file
## just dropped in works without opening the editor). null when missing or unreadable.
static func _load_glb(path: String) -> Node3D:
	if ResourceLoader.exists(path):
		var ps := load(path) as PackedScene
		if ps != null:
			var node := ps.instantiate() as Node3D
			if node != null:
				node.scene_file_path = ""  # packed below as plain nodes, not as an instance of the import
			return node
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		push_warning("character model %s could not be read" % path)
		return null
	return doc.generate_scene(state) as Node3D


## The model scaled, grounded, rigged and turned, packed as a scene (a resource: freed with the
## last user, where a cached node would outlive the game). body_h: standing height, which sets the
## proportions the rig looks for; arms: rig the arms too (false for the hands-up models).
static func _load_normalized(path: String, height: float, yaw_deg: float, body_h: float, arms: bool) -> PackedScene:
	var model := _load_glb(path)
	if model == null:
		return null
	var box := bounds(model)
	if box.size.y <= 0.0001:
		push_warning("character model %s has no visible mesh" % path)
		model.free()
		return null
	_fix_metal(model)
	var s := height / box.size.y
	model.scale *= s
	model.position = model.position * s - Vector3(box.get_center().x, box.position.y, box.get_center().z) * s
	var holder := Node3D.new()
	holder.name = path.get_file().get_basename()
	holder.add_child(model)
	var sk := _rig(model, body_h, arms)
	if sk != null:
		holder.remove_child(model)
		model.free()
		holder.add_child(sk)
	holder.rotation_degrees.y = yaw_deg
	var turned := bounds(holder)  # lying on its back the figure's back (min x) touches the floor
	holder.set_meta("lie_y", -turned.position.x)
	_own(holder, holder)
	var packed := PackedScene.new()
	var err := packed.pack(holder)
	holder.free()
	if err != OK:
		push_warning("character model %s could not be prepared" % path)
		return null
	print("[characters] %s: %.2f m tall (scaled x%.3f)" % [path.get_file(), height, s])
	return packed


## Image-to-3D generators often leave the glTF default metallic 1.0 without a metallic texture:
## cloth and skin would then render dark like metal. Such a material is made non-metallic.
static func _fix_metal(model: Node3D) -> void:
	for mi in meshes(model):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if mat != null and mat.metallic_texture == null and mat.metallic > 0.99:
				mat.metallic = 0.0


static func _own(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_own(c, owner)


# ---- auto-rig ---------------------------------------------------------------

## Skins the model to a skeleton guessed from its shape and returns it (meshes baked into the
## holder's space), or null when the model has its own skeleton or no mesh. h: standing height.
## Legs split at the gap between them, hips and knees at human proportions; upper arms run from
## the shoulders down the outer edge of the body, forearms and hands are what the mesh joins to
## the wrist. Weights blend over a few centimetres at every joint so the surface bends, not tears.
static func _rig(model: Node3D, h: float, arms: bool) -> Skeleton3D:
	if not model.find_children("*", "Skeleton3D", true, false).is_empty():
		return null
	var parts: Array = []  # [source mesh, [surface arrays], [materials]]
	var pts := PackedVector3Array()
	var tris := PackedInt32Array()  # into pts
	for entry in _mesh_transforms(model, model.transform):
		var mi: MeshInstance3D = entry[0]
		if mi.skin != null:
			return null
		if mi.mesh == null:
			continue
		var surfaces: Array = []
		var mats: Array = []
		for i in mi.mesh.get_surface_count():
			var arr := _bake(mi.mesh.surface_get_arrays(i), entry[1])
			var base := pts.size()
			pts.append_array(arr[Mesh.ARRAY_VERTEX])
			var prim := (mi.mesh as ArrayMesh).surface_get_primitive_type(i) if mi.mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
			if prim == Mesh.PRIMITIVE_TRIANGLES:
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(pts.size() - base))
				for k in idx:
					tris.append(base + k)
			surfaces.append(arr)
			mats.append(mi.get_active_material(i))
		parts.append([mi.mesh, surfaces, mats])
	if pts.is_empty():
		return null
	var j := _joints(pts, h, arms)
	var g := _graph(pts, tris)
	j["weld"] = g["weld"]
	if arms:
		for side: int in [1, -1]:
			var arm: Dictionary = j["arm_l" if side > 0 else "arm_r"]
			arm["flood"] = _forearm(g, j["gx"], side, h, arm["thigh"])
	var sk := Skeleton3D.new()
	sk.name = "skeleton"
	var skin := Skin.new()
	var at: Array[Vector3] = j["at"]
	for b in BONE_NAMES.size():
		sk.add_bone(BONE_NAMES[b])
		var parent := BONE_PARENTS[b]
		if parent >= 0:
			sk.set_bone_parent(b, parent)
		sk.set_bone_rest(b, Transform3D(Basis(), at[b] - (at[parent] if parent >= 0 else Vector3.ZERO)))
		skin.add_bind(b, Transform3D(Basis(), -at[b]))
	sk.reset_bone_poses()
	sk.set_meta("leg_len", at[Bone.HIPS].y)
	var fused := false
	if arms:
		for key in ["arm_l", "arm_r"]:
			fused = fused or bool((j[key]["flood"] as Dictionary).get("fused", false))
	sk.set_meta("fused_hand", fused)
	var base := 0
	var smooth: PackedVector3Array = g["nrm"]
	var weld: PackedInt32Array = g["weld"]
	for part in parts:
		var src: Mesh = part[0]
		var am := ArrayMesh.new()
		for i in (part[1] as Array).size():
			var arr: Array = part[1][i]
			_skin_weights(arr, j, base)
			if arr[Mesh.ARRAY_NORMAL] == null:  # image-to-3D output often has none: lights then shade it wrong
				var nrm := PackedVector3Array()
				nrm.resize((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
				for k in nrm.size():
					nrm[k] = smooth[weld[base + k]].normalized()
				arr[Mesh.ARRAY_NORMAL] = nrm
			base += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var prim := (src as ArrayMesh).surface_get_primitive_type(i) if src is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
			am.add_surface_from_arrays(prim, arr)
			am.surface_set_material(i, part[2][i])
		var mi := MeshInstance3D.new()
		mi.mesh = am
		mi.skin = skin
		sk.add_child(mi)
		mi.skeleton = NodePath("..")
	return sk


## Surface arrays with positions, normals and tangents moved by xf.
static func _bake(arr: Array, xf: Transform3D) -> Array:
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in v.size():
		v[i] = xf * v[i]
	arr[Mesh.ARRAY_VERTEX] = v
	var nb := xf.basis.inverse().transposed()
	if arr[Mesh.ARRAY_NORMAL] != null:
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in nrm.size():
			nrm[i] = (nb * nrm[i]).normalized()
		arr[Mesh.ARRAY_NORMAL] = nrm
	if arr[Mesh.ARRAY_TANGENT] != null:
		var t: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT]
		for i in range(0, t.size(), 4):
			var d := (xf.basis * Vector3(t[i], t[i + 1], t[i + 2])).normalized()
			t[i] = d.x
			t[i + 1] = d.y
			t[i + 2] = d.z
		arr[Mesh.ARRAY_TANGENT] = t
	return arr


## Joints read off the vertices, cut into rows 2 % of the height tall; heights are kept within human
## proportions of h. Returns "at" (bone positions, in Bone order) and what _skin_weights needs: the
## leg gap x, crotch, hip and knee heights, and per side the arm's inner edge for every row, the
## bottom of the hand and the shoulder height.
static func _joints(pts: PackedVector3Array, h: float, arms: bool) -> Dictionary:
	var band := 0.02 * h
	var top := 0.0
	for p in pts:
		top = maxf(top, p.y)
	var rows: Array[Array] = []
	for k in int(top / band) + 1:
		rows.append([])
	for p in pts:
		rows[clampi(int(p.y / band), 0, rows.size() - 1)].append(p)
	var row := func(y: float) -> int: return clampi(int(y / band), 0, rows.size() - 1)
	# the leg gap: middle of the lower legs
	var lo := _span(rows, 0, row.call(0.3 * h), 0.0, 0)
	var gx := (lo[0] + lo[1]) * 0.5 if lo[0] <= lo[1] else 0.0
	# crotch: the lowest height where something fills the gap (two rows running)
	var crotch := 0.42 * h
	var filled := 0
	for k in range(row.call(0.25 * h), row.call(0.6 * h)):
		var inside := 0
		for p in rows[k]:
			if absf((p as Vector3).x - gx) < 0.008 * h:
				inside += 1
		filled = filled + 1 if inside >= 2 else 0
		if filled == 2:
			crotch = (k - 1) * band
			break
	crotch = clampf(crotch, 0.4 * h, 0.46 * h)  # baggy trousers close the gap early, gear between the legs late
	var hip_y := clampf(crotch + 0.07 * h, 0.49 * h, 0.53 * h)
	var knee_y := 0.27 * h
	var pelvis := _span(rows, row.call(hip_y - 0.03 * h), row.call(hip_y + 0.03 * h), gx, 0)
	var hz := (pelvis[2] + pelvis[3]) * 0.5 if pelvis[0] <= pelvis[1] else 0.0
	var at: Array[Vector3] = []
	at.resize(BONE_NAMES.size())
	at[Bone.HIPS] = Vector3(gx, hip_y, hz)
	at[Bone.SPINE] = Vector3(gx, hip_y + 0.12 * h, hz)
	var out := {"at": at, "gx": gx, "h": h, "band": band, "crotch": crotch, "hip_y": hip_y, "knee_y": knee_y, "arms": arms}
	for side: int in [1, -1]:
		var thigh := _span(rows, row.call(0.29 * h), row.call(0.36 * h), gx, side)  # mid-thigh, below the hands
		var tx := thigh[4] if thigh[0] <= thigh[1] else gx + side * 0.05 * h
		var kn := _span(rows, row.call(knee_y - 0.02 * h), row.call(knee_y + 0.02 * h), gx, side)
		var kx := kn[4] if kn[0] <= kn[1] else tx
		var kz := (kn[2] + kn[3]) * 0.5 if kn[0] <= kn[1] else hz
		at[Bone.THIGH_L if side > 0 else Bone.THIGH_R] = Vector3(tx, hip_y, hz)
		at[Bone.SHIN_L if side > 0 else Bone.SHIN_R] = Vector3(kx, knee_y, kz)
		var arm := _arm(rows, gx, side, h, band)
		out["arm_l" if side > 0 else "arm_r"] = arm
		at[Bone.ARM_L if side > 0 else Bone.ARM_R] = arm["joint"]
	return out


## Bounds [min x, max x, min z, max z, median x] of the points in rows k0..k1 on one side of gx
## (side 1: +x, -1: -x, 0: both); the median ignores a few points of a hand hanging into the rows.
## Empty: min > max.
static func _span(rows: Array[Array], k0: int, k1: int, gx: float, side: int) -> Array[float]:
	var b: Array[float] = [INF, -INF, INF, -INF, gx]
	var xs: Array[float] = []
	for k in range(maxi(k0, 0), mini(k1, rows.size() - 1) + 1):
		for p: Vector3 in rows[k]:
			if side != 0 and (p.x - gx) * side <= 0.0:
				continue
			b[0] = minf(b[0], p.x)
			b[1] = maxf(b[1], p.x)
			b[2] = minf(b[2], p.z)
			b[3] = maxf(b[3], p.z)
			xs.append(p.x)
	if not xs.is_empty():
		xs.sort()
		b[4] = xs[xs.size() / 2]
	return b


## One arm, measured as distance out from the leg gap: per row the arm's inner edge (the body's
## outer edge there, less an arm width tapering from the shoulder to the hand), the bottom of the
## hand (scanning down, the outer edge steps in from the hand to the thigh) and the shoulder joint.
static func _arm(rows: Array[Array], gx: float, side: int, h: float, band: float) -> Dictionary:
	var raw: Array[float] = []
	for k in rows.size():
		var o := -INF
		for p: Vector3 in rows[k]:
			o = maxf(o, (p.x - gx) * side)
		raw.append(o)
	var outer: Array[float] = []  # median of three rows: one stray point does not move the edge
	for k in raw.size():
		var m: Array[float] = [raw[maxi(k - 1, 0)], raw[k], raw[mini(k + 1, raw.size() - 1)]]
		m.sort()
		outer.append(m[1])
	var hand := 0.4 * h
	for k in range(mini(int(0.6 * h / band), rows.size() - 1), maxi(int(0.3 * h / band), 2), -1):
		if raw[k] - maxf(raw[k - 1], raw[k - 2]) > 0.025 * h:
			hand = k * band
			break
	var thigh := -INF  # the leg's outer edge just below the hand
	for k in range(maxi(int((hand - 0.06 * h) / band), 0), mini(int((hand - 0.015 * h) / band), raw.size() - 1) + 1):
		thigh = maxf(thigh, raw[k])
	var shoulder := 0.815 * h
	var inner: Array[float] = []
	for k in outer.size():
		var t := clampf(inverse_lerp(hand, shoulder, (k + 0.5) * band), 0.0, 1.0)
		inner.append(outer[k] - lerpf(0.035, 0.06, t) * h if outer[k] > 0.0 else INF)
	var ks := clampi(int((shoulder - 0.06 * h) / band), 0, rows.size() - 1)
	var mid := outer[ks] - 0.03 * h if outer[ks] > 0.0 else 0.17 * h
	var z := Vector2(INF, -INF)
	for p: Vector3 in rows[ks]:
		if (p.x - gx) * side > inner[ks]:
			z = Vector2(minf(z.x, p.z), maxf(z.y, p.z))
	return {"inner": inner, "hand": hand, "thigh": thigh, "shoulder": shoulder,
			"joint": Vector3(gx + side * mid, shoulder, (z.x + z.y) * 0.5 if z.x <= z.y else 0.0)}


## Writes bone indices and weights (four per vertex) into surface arrays, from the joints. base:
## index of the surface's first vertex among all the model's vertices.
static func _skin_weights(arr: Array, j: Dictionary, base: int) -> void:
	var weld: PackedInt32Array = j["weld"]
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var h: float = j["h"]
	var gx: float = j["gx"]
	var hip_y: float = j["hip_y"]
	var crotch: float = j["crotch"]
	var knee_y: float = j["knee_y"]
	var arms: Array[Dictionary] = [{}, {}]
	if j["arms"]:
		arms = [j["arm_l"], j["arm_r"]]
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	bones.resize(v.size() * 4)  # unused slots: bone 0, weight 0
	weights.resize(v.size() * 4)
	var w := PackedFloat32Array()
	w.resize(BONE_NAMES.size())
	for i in v.size():
		var p := v[i]
		w.fill(0.0)
		var left := smoothstep(gx - 0.012 * h, gx + 0.012 * h, p.x)
		var arm := _arm_weight(p, weld[base + i], arms[0] if p.x > gx else arms[1], 1 if p.x > gx else -1, gx, h, j["band"])
		var rest := 1.0 - arm
		w[Bone.ARM_L if p.x > gx else Bone.ARM_R] = arm
		var leg := rest * (1.0 - smoothstep(crotch - 0.01 * h, hip_y, p.y))
		var shin := 1.0 - smoothstep(knee_y - 0.025 * h, knee_y + 0.025 * h, p.y)
		w[Bone.THIGH_L] = leg * left * (1.0 - shin)
		w[Bone.SHIN_L] = leg * left * shin
		w[Bone.THIGH_R] = leg * (1.0 - left) * (1.0 - shin)
		w[Bone.SHIN_R] = leg * (1.0 - left) * shin
		var body := rest - leg
		var up := smoothstep(hip_y, hip_y + 0.15 * h, p.y)
		w[Bone.SPINE] = body * up
		w[Bone.HIPS] = body * (1.0 - up)
		var used := 0
		for b in w.size():
			if w[b] > 0.0001:
				used += 1
			else:
				w[b] = 0.0
		while used > 4:  # keep the four largest
			var least := -1
			for b in w.size():
				if w[b] > 0.0 and (least < 0 or w[b] < w[least]):
					least = b
			w[least] = 0.0
			used -= 1
		var total := 0.0
		var slot := i * 4
		for b in w.size():
			if w[b] > 0.0:
				bones[slot] = b
				weights[slot] = w[b]
				total += w[b]
				slot += 1
		for k in range(i * 4, slot):
			weights[k] /= total
	arr[Mesh.ARRAY_BONES] = bones
	arr[Mesh.ARRAY_WEIGHTS] = weights


## How much of point p (welded vertex wid) follows arm `a` (from _arm, on `side`; {}: no arm):
## below the elbow what the flood from the wrist reached, above it (or without a flood) the part
## outside the arm's inner edge, between the bottom of the hand and the shoulder.
static func _arm_weight(p: Vector3, wid: int, a: Dictionary, side: int, gx: float, h: float, band: float) -> float:
	if a.is_empty():
		return 0.0
	var hand: float = a["hand"]
	var inner: Array[float] = a["inner"]
	var k := clampi(int(maxf(p.y, hand) / band), 0, inner.size() - 1)
	var e: float = inner[k]
	var d := (p.x - gx) * side
	var edge := 0.0 if e == INF else smoothstep(e - 0.01 * h, e + 0.01 * h, d) * smoothstep(hand - 0.01 * h, hand, p.y) \
			* (1.0 - smoothstep(float(a["shoulder"]) - 0.05 * h, float(a["shoulder"]), p.y))
	var f: Dictionary = a["flood"]
	if f.is_empty() or p.y >= float(f["elbow"]):
		return edge
	var reached: float = (f["inside"] as PackedFloat32Array)[wid]
	return lerpf(reached, edge, smoothstep(float(f["elbow"]) - 0.04 * h, float(f["elbow"]), p.y))


## Welded vertex ids (UV seams split one corner into several vertices) and the welded mesh's
## neighbours and smooth normals: {"weld": vertex -> id, "pos": id -> position, "nrm": id -> sum of
## the area-weighted normals of its triangles, "adj": id -> [ids]}.
static func _graph(pts: PackedVector3Array, tris: PackedInt32Array) -> Dictionary:
	var ids := {}
	var weld := PackedInt32Array()
	weld.resize(pts.size())
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	for i in pts.size():
		var key := Vector3i((pts[i] * 4096.0).round())
		if not ids.has(key):
			ids[key] = pos.size()
			pos.append(pts[i])
			nrm.append(Vector3.ZERO)
		weld[i] = ids[key]
	var adj: Array[Array] = []
	adj.resize(pos.size())
	for i in adj.size():
		adj[i] = []
	for t in range(0, tris.size() - 2, 3):
		var a := pts[tris[t]]
		var n := (a - pts[tris[t + 2]]).cross(a - pts[tris[t + 1]])  # Plane(a, b, c).normal: Godot's front face
		for c in 3:
			var u := weld[tris[t + c]]
			var v := weld[tris[t + (c + 1) % 3]]
			adj[u].append(v)
			adj[v].append(u)
			nrm[u] += n
	return {"weld": weld, "pos": pos, "nrm": nrm, "adj": adj}


## Forearm and hand on `side`: everything the mesh joins to the outermost point at wrist height,
## below the elbow. A hand generated touching the thigh is joined to it: then the flood only crosses
## points out past a cut-off (or a little inside it facing the body: the palm against the thigh),
## starting at the leg's outer edge below the hand (thigh) and moving out until the flood stays
## off the leg (nothing below FLOOD_LOW). {"inside": welded id -> arm weight (1 flooded, eased
## across a join to the thigh, see _soften), "hand": its lowest point, "elbow": height, "fused":
## the hand is joined to the thigh}, or {} when no cut-off frees the arm.
static func _forearm(g: Dictionary, gx: float, side: int, h: float, thigh: float) -> Dictionary:
	var pos: PackedVector3Array = g["pos"]
	var nrm: PackedVector3Array = g["nrm"]
	var adj: Array[Array] = g["adj"]
	var elbow := 0.58 * h
	var seed := -1
	for i in pos.size():
		var p := pos[i]
		if p.y > 0.47 * h and p.y < 0.53 * h and (seed < 0 or (p.x - pos[seed].x) * side > 0.0):
			seed = i
	if seed < 0:
		return {}
	var reach := (pos[seed].x - gx) * side
	var cut := 0.0
	while cut < reach - 0.03 * h:
		var inside := PackedByteArray()
		inside.resize(pos.size())
		inside[seed] = 1
		var stack: Array[int] = [seed]
		var low := pos[seed].y
		while not stack.is_empty() and low >= FLOOD_LOW * h:
			for v: int in adj[stack.pop_back()]:
				var q := pos[v]
				var out := (q.x - gx) * side
				if inside[v] == 0 and q.y < elbow and (out > cut or (out > cut - 0.025 * h and nrm[v].normalized().x * side < -0.3)):
					inside[v] = 1
					low = minf(low, q.y)
					stack.append(v)
		if low >= FLOOD_LOW * h:
			var top := elbow - 0.04 * h
			return {"inside": _soften(g, inside, top, FUSE_BLEND * h), "hand": low, "elbow": elbow,
					"fused": _joined(g, inside, top) >= FUSED_EDGES}
		cut = maxf(cut + 0.005 * h, thigh + 0.005 * h)
	return {}


## Edges joining the flood to the rest of the mesh below `top`: none for a hand hanging free.
static func _joined(g: Dictionary, inside: PackedByteArray, top: float) -> int:
	var pos: PackedVector3Array = g["pos"]
	var adj: Array[Array] = g["adj"]
	var n := 0
	for i in inside.size():
		if inside[i] == 1 and pos[i].y < top:
			for v: int in adj[i]:
				if inside[v] == 0 and pos[v].y < top:
					n += 1
	return n


## Arm weight per welded id from the flood: 1 inside, 0 outside, except where the mesh joins the
## forearm or hand to something else below `top` (a hand generated touching the thigh). There the
## weight runs 1 -> 0 over `r` along the surface, half on each side of the cut, so the join
## stretches over a few centimetres instead of tearing into long spikes at one row of triangles.
static func _soften(g: Dictionary, inside: PackedByteArray, top: float, r: float) -> PackedFloat32Array:
	var pos: PackedVector3Array = g["pos"]
	var adj: Array[Array] = g["adj"]
	var w := PackedFloat32Array()
	w.resize(inside.size())
	for i in inside.size():
		w[i] = float(inside[i])
	for from_inside: int in [1, 0]:
		var dist := PackedFloat32Array()  # along the surface from the cut, on the other side
		dist.resize(inside.size())
		dist.fill(INF)
		var front: Array[int] = []
		for i in inside.size():
			if inside[i] == from_inside and pos[i].y < top:
				for v: int in adj[i]:
					if inside[v] != from_inside and pos[v].y < top:
						dist[i] = 0.0
						front.append(i)
						break
		while not front.is_empty():  # a few hundred points: plain relaxation is enough
			var next: Array[int] = []
			for u in front:
				for v: int in adj[u]:
					if inside[v] == from_inside or pos[v].y >= top:
						continue
					var d := dist[u] + pos[u].distance_to(pos[v])
					if d < dist[v] and d < r:
						dist[v] = d
						next.append(v)
			front = next
		for i in inside.size():
			if inside[i] != from_inside and dist[i] < r:
				var t := 0.5 * smoothstep(0.0, r, dist[i])
				w[i] = 0.5 - t if from_inside == 1 else 0.5 + t
	return w
