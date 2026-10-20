extends RefCounted
## Character models for the 3D view: assets/characters/<name>.glb (officer, enemy, civilian and the
## hands-up enemy_up / civilian_up), or from a set subfolder first (data/view3d.json characters.set).
## Any model works: it is scaled to the figure height, stood on the floor at the origin and turned to
## face +X (the rig's aim; data/view3d.json "characters" yaw_deg fixes a model that faces elsewhere).
## No file: WorldView3D keeps its primitive figure.
## Loaded once per process; every figure gets its own copy (meshes are shared).
## Each model is rigged when it loads (_rig guesses the joints from the shape and skins the mesh to
## them) and CharacterAnim poses the result. A skeleton the file brings is dropped: the poses only
## know the auto-rig's bones, so the mesh is re-rigged from its rest shape.
## No class_name on purpose: users preload this file. A new global class name is only known after
## the editor has rescanned the project, so a game started straight after git pull (no editor)
## failed to compile every script that named it.

const DIR := "res://assets/characters/"
const LOOK := preload("res://src/game/character.gdshader")
## Bones of the auto-rig, in Skeleton3D order. The model faces +Z, so its left side is +X.
enum Bone { HIPS, SPINE, CHEST, HEAD, THIGH_L, SHIN_L, FOOT_L, THIGH_R, SHIN_R, FOOT_R, UPPER_ARM_L, FOREARM_L, UPPER_ARM_R, FOREARM_R }
const BONE_NAMES: Array[String] = ["hips", "spine", "chest", "head", "thigh_l", "shin_l", "foot_l", "thigh_r", "shin_r", "foot_r",
		"upper_arm_l", "forearm_l", "upper_arm_r", "forearm_r"]
const BONE_PARENTS: Array[int] = [-1, Bone.HIPS, Bone.SPINE, Bone.CHEST, Bone.HIPS, Bone.THIGH_L, Bone.SHIN_L, Bone.HIPS, Bone.THIGH_R,
		Bone.SHIN_R, Bone.CHEST, Bone.UPPER_ARM_L, Bone.CHEST, Bone.UPPER_ARM_R]
## Joint heights as shares of the standing height (adult proportions; hips come from the shape).
const KNEE_Y := 0.27
const ANKLE_Y := 0.05
const CHEST_Y := 0.71
const NECK_Y := 0.86
const SHOULDER_Y := 0.815
const ELBOW_Y := 0.62
const FLOOD_TOP := 0.58  ## the wrist flood stays below this share (under the elbow) when the arm is merged with the body
const ARM_TOPS: Array[float] = [0.77, 0.72, 0.66, FLOOD_TOP]  ## heights the wrist flood tries, highest first
const FLOOD_LOW := 0.36  ## share of the height no hand reaches down to: a flood from the wrist below it ran into a leg

static var folder := DIR  ## where make() looks (tests point it elsewhere)
static var _templates: Dictionary = {}  ## file path -> normalized model as a PackedScene, or null when missing / unreadable


## A fresh copy of model `name`: {"node": Node3D, "overlay": StandardMaterial3D, "name": name, "lie_y" / "lie_front":
## float, "skeleton": Skeleton3D or null} (overlay tints every surface; lie_y / lie_front lift the
## figure lying on its back / front; skeleton is the auto-rig CharacterAnim poses). {} without a file.
## A hands-up model (<kind>_up) is fitted to up_height_m, fingertips included, so the body keeps the
## size of the standing model; its raised arms stay part of the chest.
## cfg "set" names a subfolder tried first (assets/characters/<set>/<name>.glb); a model missing
## there comes from the folder itself, so a new set can arrive one file at a time.
static func make(name: String, cfg: Dictionary, dir := "") -> Dictionary:
	var base := dir if dir != "" else folder
	var set_name := str(cfg.get("set", ""))
	if set_name != "":
		var m := _make(base + set_name + "/" + name + ".glb", name, cfg)
		if not m.is_empty():
			return m
	return _make(base + name + ".glb", name, cfg)


## The model names of `kind` that exist: kind itself, then kind_2, kind_3 ... (up to kind_9), from
## the model set's folder or the folder itself.
static func variants(kind: String, cfg: Dictionary, dir := "") -> Array[String]:
	var base := dir if dir != "" else folder
	var set_name := str(cfg.get("set", ""))
	var out: Array[String] = [kind]
	for k in range(2, 10):
		var nm := "%s_%d" % [kind, k]
		for path in ([base + set_name + "/" + nm + ".glb"] if set_name != "" else []) + [base + nm + ".glb"]:
			if ResourceLoader.exists(path) or FileAccess.file_exists(path):
				out.append(nm)
				break
	return out


static func _make(path: String, name: String, cfg: Dictionary) -> Dictionary:
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
	return {"node": node, "overlay": overlay, "name": name, "lie_y": float(node.get_meta("lie_y", 0.15)),
			"lie_front": float(node.get_meta("lie_front", 0.15)), "skeleton": node.get_node_or_null("skeleton") as Skeleton3D}


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
	var turned := bounds(holder)  # lying on its back the figure's back (min x) touches the floor, on its front the front
	holder.set_meta("lie_y", -turned.position.x)
	holder.set_meta("lie_front", turned.end.x)
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
## holder's space), or null when the model has no mesh. h: standing height. A model that brings its
## own skeleton is re-rigged from its rest shape (its bones and weights are replaced).
## Legs split at the gap between them; hips, knees, ankles, chest, neck and elbows sit at human
## proportions; upper arms run from the shoulders down the outer edge of the body, forearms and
## hands are what the mesh joins to the wrist. Weights blend over a few centimetres at every joint
## so the surface bends instead of tearing. The skeleton's metadata tells CharacterAnim where the
## hands are ("hand_l" / "hand_r"), the leg length ("leg_len"), the height ("h") and whether the arms
## are rigged ("arms"); "arm_free" (left, right) is how high each arm was followed apart from the
## body, as a share of h (0: not at all, the arm is cut off the body's outline instead).
static func _rig(model: Node3D, h: float, arms: bool) -> Skeleton3D:
	var parts: Array = []  # [source mesh, [surface arrays], [materials], [primitive types]]
	var pts := PackedVector3Array()
	var tris := PackedInt32Array()  # into pts
	for entry in _mesh_transforms(model, model.transform):
		var mi: MeshInstance3D = entry[0]
		if mi.mesh == null:
			continue
		var surfaces: Array = []
		var mats: Array = []
		var prims: Array = []
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
			prims.append(prim)
		parts.append([mi.mesh, surfaces, mats, prims])
	if pts.is_empty():
		return null
	var j := _joints(pts, h, arms)
	var g := _graph(pts, tris)
	j["weld"] = g["weld"]
	if arms:
		for side: int in [1, -1]:
			var arm: Dictionary = j["arm_l" if side > 0 else "arm_r"]
			arm["flood"] = _forearm(g, j["gx"], side, h, arm["thigh"])
	var at: Array[Vector3] = j["at"]
	var sk := Skeleton3D.new()
	sk.name = "skeleton"
	var skin := Skin.new()
	for b in BONE_NAMES.size():
		sk.add_bone(BONE_NAMES[b])
		var parent := BONE_PARENTS[b]
		if parent >= 0:
			sk.set_bone_parent(b, parent)
		sk.set_bone_rest(b, Transform3D(Basis(), at[b] - (at[parent] if parent >= 0 else Vector3.ZERO)))
		skin.add_bind(b, Transform3D(Basis(), -at[b]))
	sk.reset_bone_poses()
	sk.set_meta("leg_len", at[Bone.HIPS].y)
	sk.set_meta("h", h)
	sk.set_meta("arms", arms)
	var free_to := PackedFloat32Array([0.0, 0.0])
	if arms:
		for side in 2:
			var f: Dictionary = j["arm_l" if side == 0 else "arm_r"]["flood"]
			free_to[side] = float(f["top"]) / h if not f.is_empty() else 0.0
	sk.set_meta("arm_free", free_to)
	var base := 0
	var smooth: PackedVector3Array = g["nrm"]
	var weld: PackedInt32Array = g["weld"]
	var hands := [Vector3.ZERO, Vector3.ZERO, 0.0, 0.0]  # sums of hand points left / right, and their counts
	var keys := _cloth_keys(parts, h, j["gx"])
	var prof := _profile(pts, h, j["gx"])
	keys["head"] = Vector3(float(prof["head_top"]), float(prof["face_z"]), float(prof["head_back"])) / h
	var looks := {}  # source material -> its look ShaderMaterial (shared by the surfaces using it)
	for part in parts:
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
			if arms:
				_hand_points(arr, j, hands)
				if part[3][i] == Mesh.PRIMITIVE_TRIANGLES:
					_unbridge(arr, j)
			base += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var rest := PackedFloat32Array()  # CUSTOM0: rest position / height, for the look shader's masks
			for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
				rest.append_array([v.x / h, v.y / h, v.z / h, 0.0])
			arr[Mesh.ARRAY_CUSTOM0] = rest
			am.add_surface_from_arrays(part[3][i], arr, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			var src: Material = part[2][i]
			if not looks.has(src):
				looks[src] = _look_material(src, keys)
			am.surface_set_material(i, looks[src])
		var mi := MeshInstance3D.new()
		mi.mesh = am
		mi.skin = skin
		sk.add_child(mi)
		mi.skeleton = NodePath("..")
	for side in 2:
		var fallback := at[Bone.FOREARM_L if side == 0 else Bone.FOREARM_R] - Vector3(0.0, 0.17 * h, 0.0)
		sk.set_meta("hand_l" if side == 0 else "hand_r", hands[side] / hands[side + 2] if hands[side + 2] > 0.0 else fallback)
	sk.set_meta("profile", prof)
	sk.set_meta("keys", keys)
	return sk


## The colours the garments were made in: the upper garment (front of the chest, 0.6..0.76 of the
## height) and the trousers (thighs, 0.3..0.44), read from the texture under those vertices. Each
## is the mean of the samples near their first mean (seams, logos and hands left out). Also
## "top_low": how far down the front of the body the top goes (a shirt tucked in at the belt, a
## hoodie lower), and "gx": the body's middle (x), both as shares of the height.
static func _cloth_keys(parts: Array, h: float, gx: float) -> Dictionary:
	var top: Array[Color] = []
	var bottom: Array[Color] = []
	var column: Array = []  # [height share, colour] down the front of the waist
	for part in parts:
		for i in (part[1] as Array).size():
			var arr: Array = part[1][i]
			var mat := part[2][i] as BaseMaterial3D
			var uvs: Variant = arr[Mesh.ARRAY_TEX_UV]
			if mat == null or uvs == null:
				continue
			var img: Image = null
			if mat.albedo_texture != null:
				img = mat.albedo_texture.get_image()
				if img != null and img.is_compressed():
					img = img.duplicate()
					img.decompress()
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for k in verts.size():
				var p := verts[k] / h
				var front := absf(p.x - gx / h) < 0.07 and p.z > 0.0
				var in_top := p.y > 0.6 and p.y < 0.76 and front
				var in_bottom := p.y > 0.3 and p.y < 0.44
				var in_waist := p.y > 0.4 and p.y <= 0.6 and absf(p.x - gx / h) < 0.05 and p.z > 0.0
				if not (in_top or in_bottom or in_waist):
					continue
				var c := mat.albedo_color
				if img != null and not img.is_empty():
					var uv: Vector2 = (uvs as PackedVector2Array)[k]
					c *= img.get_pixel(int(fposmod(uv.x, 1.0) * img.get_width()) % img.get_width(), int(fposmod(uv.y, 1.0) * img.get_height()) % img.get_height())
				if in_top:
					top.append(c)
				if in_bottom:
					bottom.append(c)
				if in_top or in_waist:
					column.append([p.y, c])
	var keys := {"top": _robust_mean(top, Color(0.5, 0.5, 0.5)), "bottom": _robust_mean(bottom, Color(0.2, 0.2, 0.2))}
	# where the top ends at the front of the waist: a shirt tucked in at the belt, a hoodie lower
	var low := 1.0
	var tk: Color = keys["top"]
	var bk: Color = keys["bottom"]
	var hue := func(a: Color) -> Vector3:  # colour direction, brightness left out (lit or in a fold alike)
		var g := Vector3(sqrt(a.r), sqrt(a.g), sqrt(a.b))
		return g / maxf(g.x + g.y + g.z, 0.001)
	var bright := func(a: Color) -> float: return sqrt(a.r) + sqrt(a.g) + sqrt(a.b)
	var as_top := func(c: Color) -> bool:  # nearer the top's colour than the trousers' (hue, then brightness)
		var dt: float = (hue.call(c) as Vector3).distance_to(hue.call(tk)) + absf(bright.call(c) - bright.call(tk)) * 0.08
		var db: float = (hue.call(c) as Vector3).distance_to(hue.call(bk)) + absf(bright.call(c) - bright.call(bk)) * 0.08
		return dt < db
	column.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var misses := 0
	for e in column:
		if as_top.call(e[1]):
			low = minf(low, float(e[0]))
			misses = 0
		elif float(e[0]) < low - 0.015:
			misses += 1
			if misses >= 3:
				break  # past the waistband
	keys["top_low"] = clampf(low, 0.42, 0.6)
	keys["gx"] = gx / h
	return keys


static func _robust_mean(cs: Array[Color], fallback: Color) -> Color:
	if cs.is_empty():
		return fallback
	var m := Color(0, 0, 0)
	for c in cs:
		m += c
	m /= float(cs.size())
	var near := Color(0, 0, 0)
	var n := 0
	for c in cs:
		if Vector3(c.r - m.r, c.g - m.g, c.b - m.b).length() < 0.15:
			near += c
			n += 1
	return Color(near.r / n, near.g / n, near.b / n) if n > 0 else m


## The look ShaderMaterial (character.gdshader) standing in for a model's material: its texture,
## colour, roughness and normal map, plus the garment colours `keys`.
static func _look_material(src: Material, keys: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = LOOK
	var bm := src as BaseMaterial3D
	if bm != null:
		m.set_shader_parameter("albedo", bm.albedo_color)
		m.set_shader_parameter("has_tex", bm.albedo_texture != null)
		if bm.albedo_texture != null:
			m.set_shader_parameter("albedo_tex", bm.albedo_texture)
		m.set_shader_parameter("roughness", bm.roughness)
		m.set_shader_parameter("metallic", bm.metallic)
		if bm.normal_enabled and bm.normal_texture != null:
			m.set_shader_parameter("has_normal", true)
			m.set_shader_parameter("normal_tex", bm.normal_texture)
	else:
		m.set_shader_parameter("has_tex", false)
	m.set_shader_parameter("top_key", keys["top"])
	m.set_shader_parameter("bottom_key", keys["bottom"])
	m.set_shader_parameter("top_low", keys["top_low"])
	m.set_shader_parameter("mid_x", keys["gx"])
	m.set_shader_parameter("head", keys["head"])
	return m


## Body outline for things put on it (wounds, accessories), in rest space (meters, the model faces
## +Z): per 2 % of the height from 0.44 to 0.86, the torso's front and back (near the middle) and
## its sides; and the head: top, face front and back of the head at eye level (0.93), half width.
static func _profile(pts: PackedVector3Array, h: float, gx: float) -> Dictionary:
	var y0 := 0.44
	var dy := 0.02
	var n := int((0.86 - y0) / dy) + 1
	var front := PackedFloat32Array()
	var back := PackedFloat32Array()
	var left := PackedFloat32Array()
	var right := PackedFloat32Array()
	for arr in [front, back, left, right]:
		arr.resize(n)
	for k in n:
		front[k] = -INF
		back[k] = INF
		left[k] = -INF
		right[k] = INF
	var head := {"top": 0.0, "face": -INF, "back": INF, "half": 0.0}
	var lo := Vector3(INF, INF, INF)  # the whole mesh, for rows a sparse mesh has no points in
	var hi := -lo
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
		var y := p.y / h
		if y >= y0 and y < y0 + dy * n:
			var k := int((y - y0) / dy)
			if absf(p.x - gx) < 0.05 * h:
				front[k] = maxf(front[k], p.z)
				back[k] = minf(back[k], p.z)
			if absf(p.z) < 0.04 * h and absf(p.x - gx) < 0.14 * h:  # the arms hang further out
				left[k] = maxf(left[k], p.x)
				right[k] = minf(right[k], p.x)
		if y > 0.88:
			head["top"] = maxf(float(head["top"]), p.y)
			if absf(p.x - gx) < 0.035 * h and absf(y - 0.93) < 0.015:
				head["face"] = maxf(float(head["face"]), p.z)
				head["back"] = minf(float(head["back"]), p.z)
			if absf(y - 0.93) < 0.02:
				head["half"] = maxf(float(head["half"]), absf(p.x - gx))
	var outer := [hi.z, lo.z, hi.x, lo.x]  # front, back, left, right of the whole mesh
	var sides := [front, back, left, right]
	for k in n:  # rows the scan missed take the neighbour's value (the first one the mesh's extent)
		for j in 4:
			if absf(float(sides[j][k])) == INF:
				sides[j][k] = sides[j][k - 1] if k > 0 else float(outer[j])
	front = sides[0]
	back = sides[1]
	left = sides[2]
	right = sides[3]
	if absf(float(head["face"])) == INF:
		head["face"] = 0.06 * h
		head["back"] = -0.06 * h
	return {"y0": y0, "dy": dy, "front": front, "back": back, "left": left, "right": right, "gx": gx,
			"head_top": head["top"], "face_z": head["face"], "head_back": head["back"], "head_half": head["half"]}


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
## leg gap x, crotch, hip, knee and ankle heights, and per side the arm's inner edge for every row,
## the bottom of the hand and the shoulder height.
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
	var knee_y := KNEE_Y * h
	var ankle_y := ANKLE_Y * h
	var mid_z := func(y: float, half_w: float) -> float:  # middle front-to-back of the body near x = gx
		var s := _span(rows, row.call(y - 0.015 * h), row.call(y + 0.015 * h), gx, 0, half_w)
		return (s[2] + s[3]) * 0.5 if s[0] <= s[1] else 0.0
	var at: Array[Vector3] = []
	at.resize(BONE_NAMES.size())
	at[Bone.HIPS] = Vector3(gx, hip_y, mid_z.call(hip_y, 0.12 * h))
	at[Bone.SPINE] = Vector3(gx, hip_y + 0.1 * h, mid_z.call(hip_y + 0.1 * h, 0.1 * h))
	at[Bone.CHEST] = Vector3(gx, CHEST_Y * h, mid_z.call(CHEST_Y * h, 0.1 * h))
	at[Bone.HEAD] = Vector3(gx, NECK_Y * h, mid_z.call(NECK_Y * h, 0.04 * h))
	var out := {"at": at, "gx": gx, "h": h, "band": band, "crotch": crotch, "hip_y": hip_y, "knee_y": knee_y, "ankle_y": ankle_y, "arms": arms}
	for side: int in [1, -1]:
		var thigh := _span(rows, row.call(0.29 * h), row.call(0.36 * h), gx, side)  # mid-thigh, below the hands
		var tx := thigh[4] if thigh[0] <= thigh[1] else gx + side * 0.05 * h
		var kn := _span(rows, row.call(knee_y - 0.02 * h), row.call(knee_y + 0.02 * h), gx, side)
		var kx := kn[4] if kn[0] <= kn[1] else tx
		var kz := (kn[2] + kn[3]) * 0.5 if kn[0] <= kn[1] else at[Bone.HIPS].z
		var an := _span(rows, row.call(ankle_y + 0.01 * h), row.call(ankle_y + 0.04 * h), gx, side)  # the lower shin
		var ax := an[4] if an[0] <= an[1] else kx
		var az := (an[2] + an[3]) * 0.5 if an[0] <= an[1] else kz
		at[Bone.THIGH_L if side > 0 else Bone.THIGH_R] = Vector3(tx, hip_y, at[Bone.HIPS].z)
		at[Bone.SHIN_L if side > 0 else Bone.SHIN_R] = Vector3(kx, knee_y, kz)
		at[Bone.FOOT_L if side > 0 else Bone.FOOT_R] = Vector3(ax, ankle_y, az)
		var arm := _arm(rows, gx, side, h, band)
		out["arm_l" if side > 0 else "arm_r"] = arm
		at[Bone.UPPER_ARM_L if side > 0 else Bone.UPPER_ARM_R] = arm["joint"]
		at[Bone.FOREARM_L if side > 0 else Bone.FOREARM_R] = arm["elbow"]
	return out


## Bounds [min x, max x, min z, max z, median x] of the points in rows k0..k1 on one side of gx
## (side 1: +x, -1: -x, 0: both; half_w > 0: only within half_w of gx); the median ignores a few
## points of a hand hanging into the rows. Empty: min > max.
static func _span(rows: Array[Array], k0: int, k1: int, gx: float, side: int, half_w := 0.0) -> Array[float]:
	var b: Array[float] = [INF, -INF, INF, -INF, gx]
	var xs: Array[float] = []
	for k in range(maxi(k0, 0), mini(k1, rows.size() - 1) + 1):
		for p: Vector3 in rows[k]:
			if side != 0 and (p.x - gx) * side <= 0.0:
				continue
			if half_w > 0.0 and absf(p.x - gx) > half_w:
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
## hand (scanning down, the outer edge steps in from the hand to the thigh), the leg's outer edge
## just below the hand, and the shoulder and elbow joints.
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
	var thigh := -INF
	for k in range(maxi(int((hand - 0.06 * h) / band), 0), mini(int((hand - 0.015 * h) / band), raw.size() - 1) + 1):
		thigh = maxf(thigh, raw[k])
	var shoulder := SHOULDER_Y * h
	var inner: Array[float] = []
	for k in outer.size():
		var t := clampf(inverse_lerp(hand, shoulder, (k + 0.5) * band), 0.0, 1.0)
		inner.append(outer[k] - lerpf(0.035, 0.06, t) * h if outer[k] > 0.0 else INF)
	var joint := func(y: float, inset: float) -> Vector3:  # on the arm's centre line at height y
		var k := clampi(int(y / band), 0, rows.size() - 1)
		var mid := outer[k] - inset * h if outer[k] > 0.0 else 0.17 * h
		var z := Vector2(INF, -INF)
		for p: Vector3 in rows[k]:
			if (p.x - gx) * side > inner[k]:
				z = Vector2(minf(z.x, p.z), maxf(z.y, p.z))
		return Vector3(gx + side * mid, y, (z.x + z.y) * 0.5 if z.x <= z.y else 0.0)
	var top: Vector3 = joint.call(shoulder - 0.06 * h, 0.03)
	var elbow: Vector3 = joint.call(ELBOW_Y * h, 0.025)
	return {"inner": inner, "hand": hand, "thigh": thigh, "shoulder": shoulder,
			"joint": Vector3(top.x, shoulder, top.z), "elbow": elbow}


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
	var ankle_y: float = j["ankle_y"]
	var elbow_y := ELBOW_Y * h
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
		var on_left := p.x > gx
		var left := smoothstep(gx - 0.012 * h, gx + 0.012 * h, p.x)
		var arm := _arm_weight(p, weld[base + i], arms[0] if on_left else arms[1], 1 if on_left else -1, gx, h, j["band"])
		var fore := 1.0 - smoothstep(elbow_y - 0.025 * h, elbow_y + 0.025 * h, p.y)
		w[Bone.FOREARM_L if on_left else Bone.FOREARM_R] = arm * fore
		w[Bone.UPPER_ARM_L if on_left else Bone.UPPER_ARM_R] = arm * (1.0 - fore)
		var rest := 1.0 - arm
		var leg := rest * (1.0 - smoothstep(crotch - 0.01 * h, hip_y, p.y))
		var shin := 1.0 - smoothstep(knee_y - 0.025 * h, knee_y + 0.025 * h, p.y)
		var foot := 1.0 - smoothstep(ankle_y - 0.01 * h, ankle_y + 0.02 * h, p.y)
		w[Bone.THIGH_L] = leg * left * (1.0 - shin)
		w[Bone.SHIN_L] = leg * left * shin * (1.0 - foot)
		w[Bone.FOOT_L] = leg * left * shin * foot
		w[Bone.THIGH_R] = leg * (1.0 - left) * (1.0 - shin)
		w[Bone.SHIN_R] = leg * (1.0 - left) * shin * (1.0 - foot)
		w[Bone.FOOT_R] = leg * (1.0 - left) * shin * foot
		var body := rest - leg
		var up := smoothstep(hip_y, hip_y + 0.12 * h, p.y)
		var chest := smoothstep((CHEST_Y - 0.08) * h, CHEST_Y * h, p.y)
		var head := smoothstep((NECK_Y - 0.015) * h, (NECK_Y + 0.015) * h, p.y) * (1.0 - smoothstep(0.09 * h, 0.12 * h, absf(p.x - gx)))
		w[Bone.HIPS] = body * (1.0 - up)
		w[Bone.SPINE] = body * up * (1.0 - chest)
		w[Bone.CHEST] = body * up * chest * (1.0 - head)
		w[Bone.HEAD] = body * up * chest * head
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
## below the flood top what the flood from the wrist reached, above it (or without a flood) the
## part outside the arm's inner edge, between the bottom of the hand and the shoulder.
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
	if f.is_empty() or p.y >= float(f["top"]):
		return edge
	var reached := float((f["inside"] as PackedByteArray)[wid])
	return lerpf(reached, edge, smoothstep(float(f["top"]) - 0.04 * h, float(f["top"]), p.y))


## Adds the points of each hand (fully on the forearm, below the wrist) to sums[0 / 1] (left /
## right) and counts to sums[2 / 3]: their mean is the hand's centre the poses grip with.
static func _hand_points(arr: Array, j: Dictionary, sums: Array) -> void:
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	for side in 2:
		var a: Dictionary = j["arm_l" if side == 0 else "arm_r"]
		var f: Dictionary = a["flood"]
		var low: float = f["hand"] if not f.is_empty() else float(a["hand"])
		var bone := Bone.FOREARM_L if side == 0 else Bone.FOREARM_R
		for i in v.size():
			if bones[i * 4] == bone and w[i * 4] > 0.99 and v[i].y < low + 0.06 * float(j["h"]):
				sums[side] += v[i]
				sums[side + 2] += 1.0


## Drops the triangles that tie a hand to the leg it was generated touching (a palm merged into
## the trousers): below the elbow, any triangle joining arm and non-arm points that stretches to
## over four times its size (and 8 cm) with the forearms raised in front. Without them the hand
## leaves the thigh cleanly instead of pulling a sheet of skin along. (Higher up, where a sleeve
## merges into the side of the body, the gap would show with the arms down, so the cloth stretches.)
static func _unbridge(arr: Array, j: Dictionary) -> void:
	if arr[Mesh.ARRAY_INDEX] == null:
		return
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var at: Array[Vector3] = j["at"]
	var lift := Basis(Vector3.RIGHT, -deg_to_rad(80.0))  # upper arms forward
	var bend := Basis(Vector3.RIGHT, -deg_to_rad(60.0))  # and the elbows bent
	var moved := PackedVector3Array()
	moved.resize(v.size())
	for i in v.size():
		var p := v[i]
		var q := p
		for s in 4:
			var b := bones[i * 4 + s]
			var wt := w[i * 4 + s]
			if wt <= 0.0:
				continue
			var sh := at[Bone.UPPER_ARM_L if b == Bone.UPPER_ARM_L or b == Bone.FOREARM_L else Bone.UPPER_ARM_R]
			if b == Bone.UPPER_ARM_L or b == Bone.UPPER_ARM_R:
				q += wt * (sh + lift * (p - sh) - p)
			elif b == Bone.FOREARM_L or b == Bone.FOREARM_R:
				var el := at[b]
				var el_moved := sh + lift * (el - sh)
				q += wt * (el_moved + lift * (bend * (p - el)) - p)
		moved[i] = q
	var top := FLOOD_TOP * float(j["h"])
	var arm := PackedFloat32Array()  # how much of each point follows an arm
	arm.resize(v.size())
	for i in v.size():
		for s in 4:
			if bones[i * 4 + s] >= Bone.UPPER_ARM_L:
				arm[i] += w[i * 4 + s]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var kept := PackedInt32Array()
	for t in range(0, idx.size() - 2, 3):
		var a := idx[t]
		var b := idx[t + 1]
		var c := idx[t + 2]
		var most := maxf(arm[a], maxf(arm[b], arm[c]))
		var least := minf(arm[a], minf(arm[b], arm[c]))
		if v[a].y < top and v[b].y < top and v[c].y < top and most > 0.5 and least < 0.5:
			var before := maxf(v[a].distance_to(v[b]), maxf(v[b].distance_to(v[c]), v[c].distance_to(v[a])))
			var after := maxf(moved[a].distance_to(moved[b]), maxf(moved[b].distance_to(moved[c]), moved[c].distance_to(moved[a])))
			if after > maxf(before * 4.0, 0.08):
				continue
		kept.append(a)
		kept.append(b)
		kept.append(c)
	arr[Mesh.ARRAY_INDEX] = kept


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


## The arm on `side` as far up as the mesh keeps it apart from the body: everything the mesh joins
## to the outermost point at wrist height, below a top height. An arm modelled clear of the body
## (A-pose) is followed up to near the armpit, so the whole arm moves without dragging the body
## along; an arm merged with the body's side leaks into the torso (reaches the middle) from high
## up, so the top steps down, at worst to FLOOD_TOP (forearm and hand). A hand generated touching
## the thigh is joined to it: then the flood only crosses points out past a cut-off (or a little
## inside it facing the body: the palm against the thigh), starting at the leg's outer edge below
## the hand (thigh) and moving out until the flood stays off the leg (nothing below FLOOD_LOW).
## {"inside": welded id -> 1, "hand": its lowest point, "top": height}, or {} when nothing frees it.
static func _forearm(g: Dictionary, gx: float, side: int, h: float, thigh: float) -> Dictionary:
	for top: float in ARM_TOPS:
		var f := _flood_arm(g, gx, side, h, thigh, top * h)
		if not f.is_empty():
			return f
	return {}


## One try of _forearm with the flood kept below `top` (m).
static func _flood_arm(g: Dictionary, gx: float, side: int, h: float, thigh: float, top: float) -> Dictionary:
	var pos: PackedVector3Array = g["pos"]
	var nrm: PackedVector3Array = g["nrm"]
	var adj: Array[Array] = g["adj"]
	var mid := 0.05 * h  # an arm never comes this close to the body's middle; a flood that does is in the torso
	var cut_top := FLOOD_TOP * h  # the cut-off only parts hand from thigh: above the forearm it does not apply
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
		var torso := false
		while not stack.is_empty() and low >= FLOOD_LOW * h and not torso:
			for v: int in adj[stack.pop_back()]:
				var q := pos[v]
				var out := (q.x - gx) * side
				if inside[v] == 0 and q.y < top and (out > cut or q.y >= cut_top or (out > cut - 0.025 * h and nrm[v].normalized().x * side < -0.3)):
					inside[v] = 1
					low = minf(low, q.y)
					torso = torso or out < mid
					stack.append(v)
		if low >= FLOOD_LOW * h and not torso:
			return {"inside": inside, "hand": low, "top": top}
		cut = maxf(cut + 0.005 * h, thigh + 0.005 * h)
	return {}
