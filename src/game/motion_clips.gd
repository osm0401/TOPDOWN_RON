extends RefCounted
## Motion-capture clips for the auto-rigged characters: assets/anim/<clip>.glb (or .gltf / .fbx), a
## file with a humanoid skeleton and one animation (Mixamo, Meshy / Higgsfield "3D Rigging", Rokoko,
## Blender exports). Any mesh in the file is ignored. Guide: docs/13-characters-mocap.md.
## The clip is read once and baked into what the auto-rig understands, so it fits any model whatever
## its proportions or rest pose (A-pose, T-pose):
## - limbs as directions: thigh, shin, upper arm and forearm (each side) point where the clip's do
## - hips, spine, chest, head and feet as turns away from the clip skeleton's rest pose
## - the hips' rise and fall as a share of the leg length (travel forward is dropped: in place)
## The clip skeleton's facing is found from its rest pose (left shoulder vs right, hips to head), so
## a file exported Z-up or facing another way still lands facing the model's front.
## Bones are found by name (Mixamo "mixamorig:LeftUpLeg", Meshy "LeftUpLeg", Godot humanoid
## "LeftUpperLeg", "thigh_l" style...). Spine and chest come from the chain between the hips and the
## shoulders, so their names do not matter.
## CharacterAnim decides when a clip plays and how much of the body it moves (data/view3d.json
## characters.clips). No class_name: preloaded (see character_models.gd).

const DIR := "res://assets/anim/"
const EXTS: Array[String] = ["glb", "gltf", "fbx"]
const FPS := 30.0
## Baked parts. Directions (unit vectors, model space: +X left, +Y up, +Z front), in this order:
enum Dir { THIGH_L, SHIN_L, THIGH_R, SHIN_R, UPPER_ARM_L, FOREARM_L, UPPER_ARM_R, FOREARM_R }
## Turns away from rest (model space), in this order:
enum Rot { HIPS, SPINE, CHEST, HEAD, FOOT_L, FOOT_R }
## Name keys (lower case, no separators, prefixes like "mixamorig:" cut) for each needed bone.
const NAMES := {
	"hips": ["hips", "pelvis", "hip"],
	"head": ["head"],
	"neck": ["neck", "neck1", "neck01"],
	"up_leg_l": ["leftupleg", "leftupperleg", "leftthigh", "thighl", "lthigh", "upperlegl", "luplegs", "lupleg"],
	"leg_l": ["leftleg", "leftlowerleg", "leftcalf", "leftshin", "calfl", "shinl", "lowerlegl", "lcalf", "lleg"],
	"foot_l": ["leftfoot", "footl", "lfoot"],
	"arm_l": ["leftarm", "leftupperarm", "upperarml", "lupperarm", "larm"],
	"fore_l": ["leftforearm", "leftlowerarm", "forearml", "lowerarml", "lforearm"],
	"hand_l": ["lefthand", "handl", "lhand"],
	"up_leg_r": ["rightupleg", "rightupperleg", "rightthigh", "thighr", "rthigh", "upperlegr", "rupleg"],
	"leg_r": ["rightleg", "rightlowerleg", "rightcalf", "rightshin", "calfr", "shinr", "lowerlegr", "rcalf", "rleg"],
	"foot_r": ["rightfoot", "footr", "rfoot"],
	"arm_r": ["rightarm", "rightupperarm", "upperarmr", "rupperarm", "rarm"],
	"fore_r": ["rightforearm", "rightlowerarm", "forearmr", "lowerarmr", "rforearm"],
	"hand_r": ["righthand", "handr", "rhand"],
}

static var folder := DIR  ## where clip files are looked for (tests point it elsewhere)
static var _clips: Dictionary = {}  ## file stem -> baked clip, or {} when missing / unusable


## The baked clip `stem` (file name without extension in folder), or {} when there is no usable file.
## take: the animation's name when the file holds several (a pack); "" takes the longest.
## {"len": seconds, "frames": int, "dirs": Array[PackedVector3Array] (per frame, Dir order),
##  "rots": Array[Array[Quaternion]] (per frame, Rot order), "rise": PackedFloat32Array (hips rise per
##  frame, share of the leg length), "step": seconds into the clip where the left foot is furthest
##  ahead of the right (lines a walk up with the game's stride), "file": path}
static func get_clip(stem: String, take := "") -> Dictionary:
	var key := stem + "|" + take
	if not _clips.has(key):
		_clips[key] = {}
		for ext in EXTS:
			var path := folder + stem + "." + ext
			if ResourceLoader.exists(path) or FileAccess.file_exists(path):
				_clips[key] = bake_file(path, take)
				break
	return _clips[key]


## True when a file for clip `stem` exists (without baking it).
static func has_file(stem: String) -> bool:
	for ext in EXTS:
		var path := folder + stem + "." + ext
		if ResourceLoader.exists(path) or FileAccess.file_exists(path):
			return true
	return false


## Drops the baked clips (at quit, and for tests).
static func release() -> void:
	_clips.clear()


## Reads a clip file and bakes its (first, or longest) animation. {} with a warning when unusable.
static func bake_file(path: String, take := "") -> Dictionary:
	var root := _load(path)
	if root == null:
		push_warning("motion clip %s could not be read" % path)
		return {}
	var out := bake_scene(root, take)
	root.free()
	if out.is_empty():
		push_warning("motion clip %s has no humanoid skeleton with an animation (needs hips, legs, arms, head)" % path)
	else:
		out["file"] = path
		print("[clips] %s%s: %.2f s, %d frames" % [path.get_file(), " / " + take if take != "" else "", out["len"], out["frames"]])
	return out


static func _load(path: String) -> Node:
	if ResourceLoader.exists(path):
		var ps := load(path) as PackedScene
		if ps != null:
			return ps.instantiate()
	if not FileAccess.file_exists(path):
		return null
	var state: GLTFState
	var doc: GLTFDocument
	if path.get_extension().to_lower() == "fbx" and ClassDB.class_exists("FBXDocument"):
		doc = ClassDB.instantiate("FBXDocument")
		state = ClassDB.instantiate("FBXState")
	else:
		doc = GLTFDocument.new()
		state = GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		return null
	return doc.generate_scene(state)


## Bakes the animation of the scene `root` (a Skeleton3D and an AnimationPlayer under it): the one
## named `take` (case and a "Library/" prefix ignored), else the longest.
static func bake_scene(root: Node, take := "") -> Dictionary:
	var sks := root.find_children("*", "Skeleton3D", true, false)
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if root is Skeleton3D:
		sks.push_front(root)
	if root is AnimationPlayer:
		aps.push_front(root)
	if sks.is_empty() or aps.is_empty():
		return {}
	var sk: Skeleton3D = sks[0]
	var anim: Animation = null
	for ap: AnimationPlayer in aps:
		for n in ap.get_animation_list():
			var a := ap.get_animation(n)
			if a == null or a.get_track_count() == 0:
				continue
			if take != "":
				if String(n).get_slice("/", String(n).get_slice_count("/") - 1).to_lower() == take.to_lower():
					anim = a
					break
			elif anim == null or a.length > anim.length:
				anim = a
	if anim == null:
		return {}
	return bake(sk, anim)


## Bakes `anim` played on skeleton `sk` (only its bone tracks are read; the scene is not run).
static func bake(sk: Skeleton3D, anim: Animation) -> Dictionary:
	var bones := _find_bones(sk)
	if bones.is_empty():
		return {}
	var n := sk.get_bone_count()
	var rest_local: Array[Transform3D] = []
	for b in n:
		rest_local.append(sk.get_bone_rest(b))
	var rest := _globals(sk, rest_local)
	# facing: the clip's left (+X here), up (+Y) and front (+Z) from its rest pose
	var left: Vector3 = rest[bones["arm_l"]].origin - rest[bones["arm_r"]].origin
	left += rest[bones["up_leg_l"]].origin - rest[bones["up_leg_r"]].origin
	var up: Vector3 = rest[bones["head"]].origin - rest[bones["hips"]].origin
	if left.length_squared() < 1e-8 or up.length_squared() < 1e-8:
		return {}
	up = up.normalized()
	left = (left - up * left.dot(up)).normalized()
	var fix := Basis(left, up, left.cross(up)).transposed()  # clip space -> model space
	var leg_len: float = rest[bones["up_leg_l"]].origin.distance_to(rest[bones["leg_l"]].origin) \
			+ rest[bones["leg_l"]].origin.distance_to(rest[bones["foot_l"]].origin)
	if leg_len < 1e-5:
		return {}
	# tracks per bone
	var tracks := {}  # bone -> [position track, rotation track, scale track] (-1: none)
	for t in anim.get_track_count():
		var b := sk.find_bone(String(anim.track_get_path(t).get_concatenated_subnames()))
		if b < 0:
			continue
		var slot := -1
		match anim.track_get_type(t):
			Animation.TYPE_POSITION_3D:
				slot = 0
			Animation.TYPE_ROTATION_3D:
				slot = 1
			Animation.TYPE_SCALE_3D:
				slot = 2
		if slot < 0:
			continue
		var have: Array = tracks.get_or_add(b, [-1, -1, -1])
		have[slot] = t
	if tracks.is_empty():
		return {}
	var frames := maxi(int(round(anim.length * FPS)) + 1, 1)
	var dirs: Array[PackedVector3Array] = []
	var rots: Array[Array] = []
	var rise := PackedFloat32Array()
	var sway := PackedFloat32Array()
	var ahead := PackedFloat32Array()  # left ankle ahead of the right (m in clip space, along front)
	var rest_rot := {}
	for key in ["hips", "spine", "chest", "head", "foot_l", "foot_r"]:
		rest_rot[key] = (fix * rest[bones[key]].basis.orthonormalized() * fix.inverse()).get_rotation_quaternion()
	for f in frames:
		var time := minf(f / FPS, anim.length)
		var local := rest_local.duplicate()
		for b: int in tracks:
			var tr: Array = tracks[b]
			var xf: Transform3D = local[b]
			var pos := xf.origin
			var rot := xf.basis.get_rotation_quaternion()
			var scl := xf.basis.get_scale()
			if tr[0] >= 0:
				pos = anim.position_track_interpolate(tr[0], time)
			if tr[1] >= 0:
				rot = anim.rotation_track_interpolate(tr[1], time)
			if tr[2] >= 0:
				scl = anim.scale_track_interpolate(tr[2], time)
			local[b] = Transform3D(Basis(rot).scaled(scl), pos)
		var g := _globals(sk, local)
		var at := func(key: String) -> Vector3: return fix * g[bones[key]].origin
		var d := PackedVector3Array()
		d.resize(8)
		d[Dir.THIGH_L] = (at.call("leg_l") - at.call("up_leg_l")).normalized()
		d[Dir.SHIN_L] = (at.call("foot_l") - at.call("leg_l")).normalized()
		d[Dir.THIGH_R] = (at.call("leg_r") - at.call("up_leg_r")).normalized()
		d[Dir.SHIN_R] = (at.call("foot_r") - at.call("leg_r")).normalized()
		d[Dir.UPPER_ARM_L] = (at.call("fore_l") - at.call("arm_l")).normalized()
		d[Dir.FOREARM_L] = (at.call("hand_l") - at.call("fore_l")).normalized()
		d[Dir.UPPER_ARM_R] = (at.call("fore_r") - at.call("arm_r")).normalized()
		d[Dir.FOREARM_R] = (at.call("hand_r") - at.call("fore_r")).normalized()
		dirs.append(d)
		var r: Array[Quaternion] = []
		for key in ["hips", "spine", "chest", "head", "foot_l", "foot_r"]:
			var now := (fix * g[bones[key]].basis.orthonormalized() * fix.inverse()).get_rotation_quaternion()
			r.append((now * (rest_rot[key] as Quaternion).inverse()).normalized())
		rots.append(r)
		var hips: Vector3 = at.call("hips") - fix * rest[bones["hips"]].origin
		rise.append(hips.y / leg_len)
		sway.append(hips.x / leg_len)
		ahead.append((at.call("foot_l") - at.call("foot_r")).z)
	# a clip that walks forward turns the whole body (hips) only a little: no correction needed; the
	# side sway is kept about its mean so a clip that drifts sideways stays in place
	var mean := 0.0
	for v in sway:
		mean += v
	mean /= sway.size()
	for i in sway.size():
		sway[i] -= mean
	var best := 0
	for i in ahead.size():
		if ahead[i] > ahead[best]:
			best = i
	return {"len": maxf(anim.length, 1.0 / FPS), "frames": frames, "dirs": dirs, "rots": rots, "rise": rise, "sway": sway,
			"step": best / FPS, "loop": anim.loop_mode != Animation.LOOP_NONE}


## The clip at `time` seconds (wrapped when loop, else held at the ends): {"dirs":
## PackedVector3Array, "rots": Array[Quaternion], "rise": float, "sway": float}.
static func sample(clip: Dictionary, time: float, loop: bool) -> Dictionary:
	var length: float = clip["len"]
	var count: int = clip["frames"]
	var t := fposmod(time, length) if loop else clampf(time, 0.0, length)
	var x := t * FPS
	var a := clampi(int(floor(x)), 0, count - 1)
	var b := (a + 1) % count if loop else mini(a + 1, count - 1)
	var k := clampf(x - floor(x), 0.0, 1.0)
	var da: PackedVector3Array = clip["dirs"][a]
	var db: PackedVector3Array = clip["dirs"][b]
	var dirs := PackedVector3Array()
	dirs.resize(da.size())
	for i in da.size():
		dirs[i] = da[i].slerp(db[i], k) if da[i].dot(db[i]) < 0.9999 else da[i]
	var ra: Array = clip["rots"][a]
	var rb: Array = clip["rots"][b]
	var rots: Array[Quaternion] = []
	for i in ra.size():
		rots.append((ra[i] as Quaternion).slerp(rb[i], k))
	var rise: PackedFloat32Array = clip["rise"]
	var sway: PackedFloat32Array = clip["sway"]
	return {"dirs": dirs, "rots": rots, "rise": lerpf(rise[a], rise[b], k), "sway": lerpf(sway[a], sway[b], k)}


## Global (skeleton space) transforms of every bone from local transforms.
static func _globals(sk: Skeleton3D, local: Array) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	out.resize(local.size())
	for b in local.size():  # Skeleton3D keeps parents before children
		var p := sk.get_bone_parent(b)
		out[b] = (out[p] * (local[b] as Transform3D)) if p >= 0 else (local[b] as Transform3D)
	return out


## Bone name key: lower case, separators and a "something:" / "mixamorig" prefix dropped.
static func _key(bone: String) -> String:
	var s := bone.to_lower()
	if s.contains(":"):
		s = s.get_slice(":", s.get_slice_count(":") - 1)
	s = s.trim_prefix("mixamorig").trim_prefix("bip001").trim_prefix("bip01").trim_prefix("def-").trim_prefix("def")
	for c in ["_", ".", " ", "-"]:
		s = s.replace(c, "")
	return s


## Needed bones by role (see NAMES) plus "spine" and "chest" read from the chain, or {} when the
## skeleton is not a humanoid.
static func _find_bones(sk: Skeleton3D) -> Dictionary:
	var by_key := {}
	for b in sk.get_bone_count():
		var k := _key(sk.get_bone_name(b))
		if not by_key.has(k):
			by_key[k] = b
	var out := {}
	for role: String in NAMES:
		for k: String in NAMES[role]:
			if by_key.has(k):
				out[role] = by_key[k]
				break
	for role in ["hips", "head", "up_leg_l", "leg_l", "foot_l", "arm_l", "fore_l", "hand_l", "up_leg_r", "leg_r", "foot_r", "arm_r", "fore_r", "hand_r"]:
		if not out.has(role):
			return {}
	# chest: the bone the left arm (or its shoulder / clavicle) hangs from, below the neck;
	# spine: the first bone above the hips on the way there
	var chest := sk.get_bone_parent(out["arm_l"])
	while chest >= 0 and _ancestor_of(sk, chest, out["arm_r"]) == false:
		chest = sk.get_bone_parent(chest)
	if chest < 0:
		chest = out["hips"]
	var chain: Array[int] = []
	var b: int = chest
	while b >= 0 and b != out["hips"]:
		chain.push_front(b)
		b = sk.get_bone_parent(b)
	out["chest"] = chest
	out["spine"] = chain[0] if not chain.is_empty() else chest
	return out


## True when bone `a` is `b` or one of its ancestors.
static func _ancestor_of(sk: Skeleton3D, a: int, b: int) -> bool:
	while b >= 0:
		if b == a:
			return true
		b = sk.get_bone_parent(b)
	return false
