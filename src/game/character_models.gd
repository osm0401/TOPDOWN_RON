class_name CharacterModels
extends RefCounted
## Character models for the 3D view: assets/characters/<name>.glb (officer, enemy, civilian and the
## hands-up enemy_up / civilian_up). Any model works: it is scaled to the figure height, stood on the
## floor at the origin and turned to face +X (the rig's aim; data/view3d.json "characters" yaw_deg
## fixes a model that faces elsewhere). No file: WorldView3D keeps its primitive figure.
## Loaded once per process; every figure gets its own copy (meshes are shared).

const DIR := "res://assets/characters/"

static var folder := DIR  ## where make() looks (tests point it elsewhere)
static var _templates: Dictionary = {}  ## file path -> normalized model as a PackedScene, or null when missing / unreadable


## A fresh copy of model `name`: {"node": Node3D, "overlay": StandardMaterial3D, "lie_y": float}
## (overlay tints every surface; lie_y lifts the figure when it lies on its back). {} without a file.
## A hands-up model (<kind>_up) is fitted to up_height_m, fingertips included, so the body keeps the
## size of the standing model.
static func make(name: String, cfg: Dictionary, dir := "") -> Dictionary:
	var path := (dir if dir != "" else folder) + name + ".glb"
	if not _templates.has(path):
		var height := float(cfg.get("up_height_m", 2.05)) if name.ends_with("_up") else float(cfg.get("height_m", 1.7))
		_templates[path] = _load_normalized(path, height, float(cfg.get("yaw_deg", 90.0)))
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
	return {"node": node, "overlay": overlay, "lie_y": float(node.get_meta("lie_y", 0.15))}


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
			return ps.instantiate() as Node3D
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		push_warning("character model %s could not be read" % path)
		return null
	return doc.generate_scene(state) as Node3D


## The model scaled, grounded and turned, packed as a scene (a resource: freed with the last user,
## where a cached node would outlive the game).
static func _load_normalized(path: String, height: float, yaw_deg: float) -> PackedScene:
	var model := _load_glb(path)
	if model == null:
		return null
	var box := bounds(model)
	if box.size.y <= 0.0001:
		push_warning("character model %s has no visible mesh" % path)
		model.free()
		return null
	var s := height / box.size.y
	model.scale *= s
	model.position = model.position * s - Vector3(box.get_center().x, box.position.y, box.get_center().z) * s
	var holder := Node3D.new()
	holder.name = path.get_file().get_basename()
	holder.add_child(model)
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


static func _own(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_own(c, owner)
