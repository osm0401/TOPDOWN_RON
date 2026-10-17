extends SceneTree
## Model check for a model set (guide: docs/09-3d-models-antigravity.md). Reads
## assets/characters/<set>/ and assets/gear/<set>/ the way the game does, prints one line per check
## (PASS / WARN / FAIL, with what to change) and, unless run with --headless, saves pictures:
## tools/models/_out/<set>_characters.png (every character from the front and the side at rest, then
## in the game's poses with the set's gear) and <set>_gear.png (every gear model with its points).
##   Godot --path <project> --script res://tools/models/check_models.gd -- [--set=gemini]
## Exit code 1 when a check failed, else 0. Missing files are not failures: the game keeps the old
## model for them.

const CM := preload("res://src/game/character_models.gd")
const CA := preload("res://src/game/character_anim.gd")
const GM := preload("res://src/game/gear_models.gd")
const PEOPLE: Array[String] = ["officer", "enemy", "civilian", "enemy_up", "civilian_up"]
const NEEDED: Array[String] = ["officer", "enemy", "civilian"]  ## the hands-up models are optional
## Points each gear kind needs (grip: the origin, where the right hand holds).
const GEAR_POINTS := {
	"rifle_lethal": ["grip", "fore", "muzzle", "light", "stock", "mag"],
	"rifle_nonlethal": ["grip", "fore", "muzzle", "light", "stock", "mag"],
	"pistol": ["grip", "fore", "muzzle", "light", "mag"],
	"camera": ["grip", "fore"],
	"cuffs": [], "cap": [], "band": [],
}
const OUT := "res://tools/models/_out/"

var set_name := "gemini"
var counts := {"PASS": 0, "WARN": 0, "FAIL": 0}
var cfg: Dictionary = {}
var figs: Array = []  ## [model, pose state] posed every frame before the picture
var frames := 0
var shots: Array = []  ## [SubViewport, file]


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--set="):
			set_name = a.substr(6)
	cfg = (JsonData.load_dict("res://data/view3d.json")["characters"] as Dictionary).duplicate(true)
	cfg["set"] = set_name
	cfg["yaw_deg"] = 0.0  # pictures look at the model's front (+Z); the game turns it to +X itself
	GM.set_name = set_name
	print("== model set '%s' ==" % set_name)
	var have: Array[String] = []
	for name in PEOPLE:
		if _check_person(name):
			have.append(name)
	for kind: String in GEAR_POINTS:
		_check_gear(kind)
	print("RESULT: %d PASS, %d WARN, %d FAIL" % [counts["PASS"], counts["WARN"], counts["FAIL"]])
	if DisplayServer.get_name() == "headless":
		print("(headless: no pictures; run without --headless to save them)")
		_finish()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_people_picture(have)
	_gear_picture()


func _process(_delta: float) -> bool:
	if shots.is_empty():
		return false
	for f in figs:
		CA.pose(f[0], f[1], cfg)
	frames += 1
	if frames < 8:
		return false
	for s in shots:
		var img := (s[0] as SubViewport).get_texture().get_image()
		img.save_png(ProjectSettings.globalize_path(s[1]))
		print("picture: %s" % ProjectSettings.globalize_path(s[1]))
	_finish()
	return true


func _finish() -> void:
	for f in figs:
		var node: Node = f[0]["node"]
		if node.is_inside_tree():
			node.queue_free()
		else:
			node.free()
	figs.clear()
	CM.release()
	GM.release()
	quit(1 if counts["FAIL"] > 0 else 0)


## The set's subfolder ("" checks the old models in the folder itself; gear then is built-in).
func _sub() -> String:
	return set_name + "/" if set_name != "" else ""


func _say(level: String, what: String, text: String) -> void:
	counts[level] += 1
	print("%s  %-22s %s" % [level, what, text])


# ---- characters ---------------------------------------------------------------

## Checks one character file; true when it exists and loads.
func _check_person(name: String) -> bool:
	var path := CM.folder + _sub() + name + ".glb"
	var what := "characters/" + name
	if not FileAccess.file_exists(path):
		if NEEDED.has(name):
			_say("WARN", what, "missing: the game keeps the old model (assets/characters/%s.glb)" % name)
		return false
	var mb := FileAccess.get_file_as_bytes(path).size() / 1048576.0
	_say("PASS" if mb <= 10.0 else "WARN", what, "file %.1f MB%s" % [mb, "" if mb <= 10.0 else " (keep it under 10 MB: smaller textures)"])
	var raw := CM._load_glb(path)
	if raw == null:
		_say("FAIL", what, "the file could not be read as glTF 2.0 binary (.glb)")
		return false
	var tris := 0
	var tex := 0
	var metal := 0
	for mi in CM.meshes(raw):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(i)
			tris += ((arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arr[Mesh.ARRAY_INDEX] != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			var mat := mi.get_active_material(i) as BaseMaterial3D
			if mat != null:
				if mat.albedo_texture != null:
					tex = maxi(tex, maxi(mat.albedo_texture.get_width(), mat.albedo_texture.get_height()))
				if mat.metallic_texture == null and mat.metallic > 0.5:
					metal += 1
	_say("PASS" if tris <= 30000 else ("WARN" if tris <= 60000 else "FAIL"), what,
			"%d triangles%s" % [tris, "" if tris <= 30000 else " (budget 30000: up to nine people are on screen)"])
	if tex > 2048:
		_say("WARN", what, "texture %d px: 2048 is plenty (1024 recommended)" % tex)
	if metal > 0:
		_say("WARN", what, "%d material(s) metallic > 0.5 without a metallic texture: cloth and skin should be metallic 0" % metal)
	if not raw.find_children("*", "Skeleton3D", true, false).is_empty() or not raw.find_children("*", "AnimationPlayer", true, false).is_empty():
		_say("WARN", what, "the file has its own skeleton / animations: ignored, the game rigs the mesh itself (leave them out)")
	var box := CM.bounds(raw)
	var up := name.ends_with("_up")
	if box.size.y < 1.5 or box.size.y > (2.3 if up else 2.1):
		_say("WARN", what, "%.2f units tall: model in meters, about 1.75 m (the game rescales, but the size tells the scale was lost)" % box.size.y)
	var spread := box.size.x / maxf(box.size.y, 0.0001)
	if not up:
		if spread > 0.75:
			_say("FAIL", what, "%.2f times as wide as tall: arms held too high (T-pose?). Arms hang about 35-40 degrees out from the body" % spread)
		elif spread < 0.3:
			_say("WARN", what, "%.2f times as wide as tall: arms against the body? Keep a gap between arms and torso" % spread)
		else:
			_say("PASS", what, "A-pose width %.2f x height" % spread)
	_shape(raw, box, what)
	raw.free()
	var m := CM.make(name, cfg)
	var sk := m.get("skeleton") as Skeleton3D
	if sk == null:
		_say("FAIL", what, "could not be rigged (no mesh?)")
		if not m.is_empty():
			(m["node"] as Node).free()
		return false
	var h := float(sk.get_meta("h"))
	if not up:
		var free_to: PackedFloat32Array = sk.get_meta("arm_free")
		for side in 2:
			var side_name := "left" if side == 0 else "right"
			var f := free_to[side]
			if f >= 0.7:
				_say("PASS", what, "%s arm apart from the body up to %.2f of the height (to the armpit)" % [side_name, f])
			elif f > 0.0:
				_say("WARN", what, "%s arm joins the body below %.2f of the height: the sleeve stretches when the arm rises. Leave air between the arm and the torso" % [side_name, f])
			else:
				_say("FAIL", what, "%s arm could not be told from the body: the hand or forearm is merged with the torso or thigh. Keep about 15 cm of air between the hand and the thigh" % side_name)
			var hand: Vector3 = sk.get_meta("hand_l" if side == 0 else "hand_r")
			var out := absf(hand.x) / h
			var hy := hand.y / h
			var ok := out >= 0.15 and out <= 0.24 and hy >= 0.4 and hy <= 0.52
			_say("PASS" if ok else "WARN", what, "%s hand %.2f out, %.2f up (of the height; the poses expect about 0.19 and 0.45)" % [side_name, out, hy])
	figs.append([m, {}])  # posed and pictured later (freed in _finish)
	return true


## Facing: a figure facing -Z has its toes behind the heels (the feet stick out further back than
## the shins). Legs: between the ankles and mid-thigh nothing should fill the middle.
func _shape(raw: Node3D, box: AABB, what: String) -> void:
	var feet := Vector2(INF, -INF)
	var shins := Vector2(INF, -INF)
	var h := box.size.y
	var mid := box.get_center().x
	var rows := 12
	var filled := PackedByteArray()
	filled.resize(rows)
	for entry in CM._mesh_transforms(raw, raw.transform):
		var mi: MeshInstance3D = entry[0]
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			for p: Vector3 in mi.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]:
				var q: Vector3 = entry[1] * p
				var y := (q.y - box.position.y) / h
				if y < 0.03:
					feet = Vector2(minf(feet.x, q.z), maxf(feet.y, q.z))
				elif y > 0.12 and y < 0.2:
					shins = Vector2(minf(shins.x, q.z), maxf(shins.y, q.z))
				if y > 0.08 and y < 0.32 and absf(q.x - mid) < 0.012 * h:
					filled[clampi(int((y - 0.08) / 0.24 * rows), 0, rows - 1)] = 1
	var closed := 0
	for r in filled:
		closed += r
	if closed > rows / 4:
		_say("WARN", what, "something fills the gap between the legs (%d of %d rows from ankle to thigh): legs touching or a long coat stretch when walking. Keep the legs apart" % [closed, rows])
	else:
		_say("PASS", what, "legs apart")
	if feet.x > feet.y or shins.x > shins.y:
		return
	var toes := feet.y - shins.y  # past the shin to the front
	var heels := shins.x - feet.x  # past the shin to the back
	if heels > toes + 0.02 * h:
		_say("FAIL", what, "the feet point to -Z: the model faces backwards. Its front must face +Z (Blender: -Y)")
	else:
		_say("PASS", what, "faces +Z (toes forward)")


# ---- gear ---------------------------------------------------------------------

func _check_gear(kind: String) -> void:
	var path := GM.folder + _sub() + kind + ".glb"
	var what := "gear/" + kind
	if not FileAccess.file_exists(path):
		_say("WARN", what, "missing: the game keeps the built-in shape")
		return
	var raw := CM._load_glb(path)
	if raw == null:
		_say("FAIL", what, "the file could not be read as glTF 2.0 binary (.glb)")
		return
	var marks := {}
	GM._find_points(raw, Transform3D.IDENTITY, marks)
	var tris := 0
	var box := AABB()
	var first := true
	for entry in CM._mesh_transforms(raw, Transform3D.IDENTITY):
		var mi: MeshInstance3D = entry[0]
		if mi.mesh == null:
			continue
		var b: AABB = entry[1] * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
		for i in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(i)
			tris += ((arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arr[Mesh.ARRAY_INDEX] != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	raw.free()
	if first:
		_say("FAIL", what, "no mesh in the file")
		return
	_say("PASS" if tris <= 6000 else ("WARN" if tris <= 15000 else "FAIL"), what, "%d triangles (budget 6000)" % tris)
	var want := (GM._builtin(kind)[0] as ArrayMesh).get_aabb().get_longest_axis_size()
	var size := box.get_longest_axis_size()
	var ratio := size / want
	_say("PASS" if ratio > 0.6 and ratio < 1.6 else "WARN", what, "%.2f m long (built-in %.2f m)%s" % [size, want,
			"" if ratio > 0.6 and ratio < 1.6 else ": model in meters at real size (the game rescales it to the built-in size)"])
	var missing: Array[String] = []
	for p: String in GEAR_POINTS[kind]:
		if not marks.has(p):
			missing.append(p)
	if missing.is_empty():
		_say("PASS", what, "points %s" % ", ".join(PackedStringArray(marks.keys())))
	else:
		_say("WARN", what, "no empty node for %s: the built-in shape's point is used, the hands may miss the model" % ", ".join(PackedStringArray(missing)))
	if marks.has("muzzle"):
		var grip: Vector3 = marks.get("grip", Vector3.ZERO)
		var d: Vector3 = marks["muzzle"] - grip
		if d.z <= 0.0 or absf(d.x) > d.z * 0.3:
			_say("FAIL", what, "the muzzle is not ahead of the grip along +Z (Blender: -Y): the barrel must point +Z")
		else:
			_say("PASS", what, "barrel points +Z")


# ---- pictures -----------------------------------------------------------------

func _viewport(size: Vector2i, file: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.shadow_enabled = true
	vp.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.42, 0.43, 0.48)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	vp.add_child(env)
	shots.append([vp, OUT + set_name + file])
	return vp


func _label(text: String, at: Vector3, parent: Node3D) -> void:
	var l := Label3D.new()
	l.text = text
	l.pixel_size = 0.004
	l.font_size = 40
	l.outline_size = 10
	l.position = at
	parent.add_child(l)


## Row 1: each character from the front and from the side at rest. Rows 2-3: game poses.
func _people_picture(have: Array[String]) -> void:
	var vp := _viewport(Vector2i(1800, 1300), "_characters.png")
	var root := Node3D.new()
	vp.add_child(root)
	var x := 0.0
	for f in figs.duplicate():
		var m: Dictionary = f[0]
		var node: Node3D = m["node"]
		root.add_child(node)
		node.position = Vector3(x, 0, 0)
		var name := String(node.name)
		_label(name, Vector3(x + 0.45, 2.0, 0), root)
		var side := CM.make(name, cfg)
		root.add_child(side["node"])
		(side["node"] as Node3D).position = Vector3(x + 0.95, 0, 0)
		(side["node"] as Node3D).rotation_degrees.y = 90.0
		figs.append([side, {}])
		x += 1.9
	var S := CA.Stance
	var H := CA.Hold
	var who := func(n: String) -> String: return n if have.has(n) else ""
	var poses: Array = [
		["officer", S.STAND, H.RIFLE, {"hand": "rifle_lethal", "holster": "pistol"}, {}, "rifle"],
		["officer", S.STAND, H.PISTOL, {"hand": "pistol", "back": "rifle_nonlethal"}, {}, "pistol"],
		["officer", S.STAND, H.RIFLE, {"hand": "rifle_nonlethal", "holster": "pistol"}, {"reload": 0.4}, "reload"],
		["officer", S.WORK, H.WORK, {"hand": "camera", "back": "rifle_lethal", "holster": "pistol"}, {}, "door camera"],
		["officer", S.STAND, H.RIFLE, {"hand": "rifle_lethal"}, {"phase": 1.2, "amount": 1.0, "speed": 3.0}, "running"],
		["enemy", S.STAND, H.PISTOL_ONE, {"hand": "pistol", "cap": "cap", "band": "band"}, {"aim": Vector3(0, 0, 1)}, "aim, cap, band"],
		["enemy", S.STAND, H.HANDS_UP, {}, {}, "hands up"],
		["enemy", S.KNEEL, H.CUFFED, {"cuffs": "cuffs"}, {}, "cuffed"],
		["enemy", S.STAND, H.PISTOL_LOW, {"hand": "pistol"}, {"phase": 0.4, "amount": 1.0, "speed": 1.6}, "walking armed"],
		["civilian", S.STAND, H.NONE, {}, {"phase": 1.5, "amount": 1.0, "speed": 1.6}, "walking"],
		["civilian", S.STAND, H.STARTLED, {}, {"look": Vector3(0.5, 0, 0.8).normalized()}, "startled"],
		["civilian", S.CROUCH, H.COVER, {}, {}, "cover"],
	]
	var i := 0
	for p: Array in poses:
		var name: String = who.call(p[0])
		if name == "":
			continue
		var m := CM.make(name, cfg)
		var sk: Skeleton3D = m["skeleton"]
		var gear := {}
		for slot: String in p[3]:
			var g := GM.make(p[3][slot])
			sk.add_child(g)
			gear[slot] = g
		m["gear"] = gear
		var s := {"stance": p[1], "hold": p[2], "t": 0.0}
		s.merge(p[4], true)
		var node: Node3D = m["node"]
		root.add_child(node)
		node.position = Vector3((i % 6) * 1.5, -2.4 - (i / 6) * 2.3, 0)
		node.rotation_degrees.y = 35.0
		_label(p[5], node.position + Vector3(0, 2.0, 0), root)
		figs.append([m, s])
		i += 1
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.4
	cam.position = Vector3(3.9, -1.55, 10.0)
	root.add_child(cam)
	cam.make_current()


## Every gear kind (file or built-in) in its own cell, seen mostly from the side (barrel to the
## right) and scaled to fit, with its points as dots: grip white, fore green, muzzle red, light
## yellow, stock blue, mag purple.
func _gear_picture() -> void:
	var vp := _viewport(Vector2i(1600, 800), "_gear.png")
	var root := Node3D.new()
	vp.add_child(root)
	var colors := {"fore": Color.GREEN, "muzzle": Color.RED, "light": Color.YELLOW, "stock": Color.DODGER_BLUE, "mag": Color.MEDIUM_PURPLE}
	var i := 0
	for kind: String in GEAR_POINTS:
		var g := GM.make(kind)
		var holder := Node3D.new()
		root.add_child(holder)
		holder.add_child(g)
		var cell := Vector3((i % 4) * 1.05, -(i / 4) * 1.0, 0)
		var fit := 0.8 / maxf((g.mesh as Mesh).get_aabb().get_longest_axis_size(), 0.01)
		holder.rotation_degrees = Vector3(12, 72, 0)  # +Z (the barrel) to the right, a little from above
		holder.scale = Vector3.ONE * fit
		holder.position = cell - holder.basis * (g.mesh as Mesh).get_aabb().get_center()
		var dots := {"grip": Vector3.ZERO}
		for p: String in colors:
			if g.has_meta(p):
				dots[p] = g.get_meta(p)
		for p: String in dots:
			var dot := MeshInstance3D.new()
			var sph := SphereMesh.new()
			sph.radius = 0.014 / fit
			sph.height = 0.028 / fit
			dot.mesh = sph
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = colors.get(p, Color.WHITE)
			mat.no_depth_test = true
			dot.material_override = mat
			dot.position = dots[p]
			holder.add_child(dot)
		var size := (g.mesh as Mesh).get_aabb().get_longest_axis_size()
		var l := Label3D.new()
		l.text = "%s%s  %.2f m" % [kind, "" if GM.from_file(kind) else " (built-in)", size]
		l.pixel_size = 0.0019
		l.font_size = 36
		l.outline_size = 8
		l.position = cell + Vector3(0, -0.42, 0.5)
		root.add_child(l)
		i += 1
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.1
	cam.position = Vector3(1.575, -0.5, 3.0)
	root.add_child(cam)
	cam.make_current()
