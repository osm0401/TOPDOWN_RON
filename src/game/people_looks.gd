extends RefCounted
## Per-person looks for the character models, so one model file gives a crowd of different people:
## clothes recoloured (top, trousers), skin tone, build (height and width) and what they wear (hair,
## beanie, glasses or sunglasses, a bandana over the face, a backpack). Chosen from data/view3d.json
## "people" with a seed made of the person's kind and number, so host and client see the same
## people. Also wounds: blood soaked into the clothes where a shot hit (character.gdshader).
## No class_name: preloaded (see character_models.gd).

const CM := preload("res://src/game/character_models.gd")
const MAX_WOUNDS := 4


## The look of person `index` of `kind` ("enemy" / "civilian"): {"top", "bottom", "skin", "hair"
## (Color; alpha 0 keeps the model's own), "scale" (Vector3: width, height, width), "acc" ({slot: gear kind}),
## "tints" ({gear kind: Color}), "variant" (int, picks a model file when several exist)}.
static func pick(kind: String, index: int, cfg: Dictionary) -> Dictionary:
	var look := {"top": Color(0, 0, 0, 0), "bottom": Color(0, 0, 0, 0), "skin": Color(1, 1, 1, 0), "hair": Color(0, 0, 0, 0),
			"scale": Vector3.ONE, "acc": {}, "tints": {}, "variant": 0}
	var p: Dictionary = cfg.get(kind, {})
	if p.is_empty():
		return look
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s/%d" % [kind, index])
	look["variant"] = rng.randi() % 64
	if rng.randf() >= float(p.get("keep_top", 0.0)):
		look["top"] = Color(_one(rng, p["tops"]))
	if rng.randf() >= float(p.get("keep_bottom", 0.0)):
		look["bottom"] = Color(_one(rng, p["bottoms"]))
	var skins: Array = cfg.get("skins", ["#ffffff"])
	look["skin"] = Color(_one(rng, skins))
	var hr: Array = p.get("height", [1.0, 1.0])
	var wr: Array = p.get("width", [1.0, 1.0])
	var w := rng.randf_range(float(wr[0]), float(wr[1]))
	look["scale"] = Vector3(w, rng.randf_range(float(hr[0]), float(hr[1])), w)
	var colors: Dictionary = cfg.get("colors", {})
	if rng.randf() < float(p.get("hair_chance", 0.0)):  # painted on the scalp (the model may be bald)
		look["hair"] = Color(_one(rng, colors.get("hair", ["#20160f"])))
	var acc: Dictionary = p.get("wear", {})
	for slot: String in acc:
		var kind_worn := _weighted(rng, acc[slot])
		if kind_worn != "":
			look["acc"][slot] = kind_worn
			if colors.has(kind_worn):
				look["tints"][kind_worn] = Color(_one(rng, colors[kind_worn]))
	return look


static func _one(rng: RandomNumberGenerator, list: Array) -> String:
	return str(list[rng.randi() % list.size()])


## A choice from [[value, weight], ...] ("" = nothing).
static func _weighted(rng: RandomNumberGenerator, options: Array) -> String:
	var total := 0.0
	for o: Array in options:
		total += float(o[1])
	var r := rng.randf() * total
	for o: Array in options:
		r -= float(o[1])
		if r <= 0.0:
			return str(o[0])
	return ""


## Puts `look` on a model from CharacterModels.make(): the look shader's per-instance colours and
## the build (the model node's scale; feet stay on the floor). Gear worn comes from look["acc"].
static func apply(model: Dictionary, look: Dictionary) -> void:
	if model.is_empty():
		return
	model["look"] = look
	(model["node"] as Node3D).scale = look["scale"]
	for mi in CM.meshes(model["node"]):
		mi.set_instance_shader_parameter("top_tint", look["top"])
		mi.set_instance_shader_parameter("bottom_tint", look["bottom"])
		mi.set_instance_shader_parameter("skin_tint", look["skin"])
		mi.set_instance_shader_parameter("hair", look.get("hair", Color(0, 0, 0, 0)))


## Colours worn gear `g` of `kind` after the look's tints (hair, beanie, bandana, backpack, the
## officers' patch); other gear keeps its own materials.
static func tint(g: GeometryInstance3D, kind: String, look: Dictionary) -> void:
	var tints: Dictionary = look.get("tints", {})
	if not tints.has(kind):
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = tints[kind]
	m.roughness = 0.7 if kind == "hair" else 0.95
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if kind == "patch":  # the player colour stays readable in a dark room
		m.emission_enabled = true
		m.emission = tints[kind]
		m.emission_energy_multiplier = 0.35
	g.material_override = m


## A wound where a shot from `toward` (unit vector in the model's own space, pointing from the body
## to the shooter; the model faces +Z) hit, at `height` (share of the body height, 0.45..0.85 on the
## torso): on the front, back or side of the torso the profile found at load. radius: share of the
## height. The newest MAX_WOUNDS stay. Returns the wound (xyz rest position / height, w radius).
static func add_wound(model: Dictionary, toward: Vector3, height: float, radius: float, jitter: float) -> Vector4:
	var sk := model.get("skeleton") as Skeleton3D
	if sk == null or not sk.has_meta("profile"):
		return Vector4.ZERO
	var prof: Dictionary = sk.get_meta("profile")
	var h := float(sk.get_meta("h", 1.75))
	var k := clampi(int((height - float(prof["y0"])) / float(prof["dy"])), 0, (prof["front"] as PackedFloat32Array).size() - 1)
	var gx := float(prof["gx"])
	var ang := atan2(toward.x, toward.z)  # 0: the shooter in front
	var at: Vector3
	if absf(ang) < PI * 0.3:
		at = Vector3(gx + jitter * 0.06 * h, height * h, (prof["front"] as PackedFloat32Array)[k])
	elif absf(ang) > PI * 0.7:
		at = Vector3(gx + jitter * 0.06 * h, height * h, (prof["back"] as PackedFloat32Array)[k])
	elif toward.x > 0.0:
		at = Vector3((prof["left"] as PackedFloat32Array)[k], height * h, jitter * 0.04 * h)
	else:
		at = Vector3((prof["right"] as PackedFloat32Array)[k], height * h, jitter * 0.04 * h)
	var w := Vector4(at.x / h, at.y / h, at.z / h, radius)
	var wounds: Array = model.get_or_add("wounds", [])
	wounds.append(w)
	while wounds.size() > MAX_WOUNDS:
		wounds.pop_front()
	_show_wounds(model)
	return w


## Makes every wound a little bigger (blood spreading on someone lying still), up to max_radius.
static func spread_wounds(model: Dictionary, amount: float, max_radius: float) -> void:
	var wounds: Array = model.get("wounds", [])
	if wounds.is_empty():
		return
	for i in wounds.size():
		var w: Vector4 = wounds[i]
		w.w = minf(w.w + amount, max_radius)
		wounds[i] = w
	_show_wounds(model)


static func _show_wounds(model: Dictionary) -> void:
	var wounds: Array = model.get("wounds", [])
	for mi in CM.meshes(model["node"]):
		for i in MAX_WOUNDS:
			mi.set_instance_shader_parameter("wound%d" % i, wounds[i] if i < wounds.size() else Vector4.ZERO)
