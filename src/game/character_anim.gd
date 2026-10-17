extends RefCounted
## Procedural poses for the auto-rigged character models (CharacterModels). Every frame WorldView3D
## describes what a figure is doing (see pose()) and this turns it into bone rotations: legs
## walking, running, crouching, kneeling or lying; arms relaxed and swinging, holding a rifle or a
## pistol on the aim, working low, cuffed behind the back, covering the head or clasped behind it;
## the head looking at someone; breathing, flinching when hit, recoil when firing, reloading.
## Arms reach their grips by two-bone IK and are otherwise set by direction, so a model generated
## in another rest pose (A-pose, T-pose) lands in the same poses.
## It also places the figure's gear (gun in the hands, rifle slung on the back or in front, pistol
## in the thigh holster, cuffs, cap, armband, door camera; nodes from GearModels under the
## skeleton) and reports where the muzzle and the weapon light are.
## No class_name: preloaded (see character_models.gd).

const CM := preload("res://src/game/character_models.gd")

enum Stance { STAND, CROUCH, KNEEL, WORK, PRONE, DEAD }  ## PRONE / DEAD: WorldView3D lays the figure on its front / back
enum Hold { NONE, RIFLE, PISTOL, PISTOL_ONE, PISTOL_LOW, WORK, CUFFED, COVER, HANDS_HEAD, STARTLED, HANDS_UP }


## Poses `model` (from CharacterModels.make; nothing happens without a skeleton). `s` describes the
## figure, every key optional:
## - "t": seconds (breathing, idle sway); "seed": per-figure offset so figures do not sway in step
## - walking: "phase" (radians along the stride), "amount" (0 standing .. 1 full stride), "speed"
##   (m/s), "dir" (unit walking direction in the model's space, +Z its front)
## - "stance" (Stance), "hold" (Hold), "aim" (unit direction a PISTOL_ONE arm points, model space)
## - "look": unit direction the head turns to (model space; ZERO: straight ahead)
## - "flinch" / "recoil": 0..1, fading after a hit / a shot; "reload": 0..1 through a reload, < 0 none
## - "tremble": 0..1, fear: quicker, shallower breaths and a shaking upper body and head
## - "dt": seconds since the last pose: a new stance or hold blends in over pose blend_s from the
##   pose shown last (without "dt" it switches at once)
## Gear goes in model["gear"]: {"hand": gun or camera in the hands, "back": slung rifle, "holster":
## pistol on the thigh, "cuffs", "cap", "band"}. Afterwards model["muzzle"] / model["light"] hold the
## gun's muzzle and weapon light (skeleton space, gun's basis) while a gun is in the hands.
## cfg: data/view3d.json characters ("walk" and "pose").
static func pose(model: Dictionary, s: Dictionary, cfg: Dictionary) -> void:
	var sk := model.get("skeleton") as Skeleton3D
	if sk == null or sk.get_bone_count() != CM.BONE_NAMES.size():
		return
	if not model.has("rig"):
		model["rig"] = _rig_info(sk)
	var r: Dictionary = model["rig"]
	var h: float = r["h"]
	var gait: Dictionary = cfg["walk"]
	var pc: Dictionary = cfg["pose"]
	var q: Array[Quaternion] = []
	q.resize(CM.BONE_NAMES.size())
	q.fill(Quaternion.IDENTITY)
	var t := float(s.get("t", 0.0)) + float(s.get("seed", 0.0))
	var stance: int = s.get("stance", Stance.STAND)
	var hold: int = s.get("hold", Hold.NONE)
	var amount := float(s.get("amount", 0.0)) if stance == Stance.STAND else 0.0
	var speed := float(s.get("speed", 0.0))
	var phase := float(s.get("phase", 0.0))
	var dir: Vector3 = s.get("dir", Vector3.BACK)
	if dir.length_squared() < 0.5:
		dir = Vector3.BACK
	var run := clampf(inverse_lerp(float(gait["walk_mps"]), float(gait["run_mps"]), speed), 0.0, 1.0)
	var flinch := float(s.get("flinch", 0.0))
	var recoil := float(s.get("recoil", 0.0))
	var aiming := hold == Hold.RIFLE or hold == Hold.PISTOL or hold == Hold.PISTOL_ONE

	# legs and hips
	var hip_off := _legs(r, q, stance, amount, phase, run, dir, gait, t)

	# spine, chest: lean into the stride, counter-twist (less on the aim), breathe, flinch, recoil
	var swing := Vector3(-dir.z, 0.0, dir.x)  # turning about this axis moves a hanging limb toward dir
	var fwd := dir.z * amount * sin(phase)
	var lean := _gait(gait, "lean_deg", run) * amount
	var twist := _gait(gait, "twist_deg", run) * fwd * (0.2 if aiming else 1.0)
	var tremble := float(s.get("tremble", 0.0))  # frightened: quick shallow breaths, a shaking upper body
	var breath := sin(t * TAU * float(pc["breath_hz"]) * (1.0 + 1.6 * tremble)) * deg_to_rad(float(pc["breath_deg"])) * (1.0 + 0.5 * tremble)
	var shake := (sin(t * 37.0) * 0.6 + sin(t * 23.0 + 1.3) * 0.4) * deg_to_rad(1.4) * tremble
	var back := deg_to_rad(float(pc["flinch_deg"])) * flinch + deg_to_rad(float(pc["recoil_deg"])) * recoil
	var bend := 0.0  # forward bend of the upper body for the stance
	match stance:
		Stance.CROUCH:
			bend = deg_to_rad(28.0)
		Stance.KNEEL:
			bend = deg_to_rad(6.0)
		Stance.WORK:
			bend = deg_to_rad(18.0)
	var blade := 0.0  # a rifle is held with the left shoulder turned forward
	if hold == Hold.RIFLE:
		blade = -deg_to_rad(float(pc["rifle_blade_deg"]))
	elif hold == Hold.PISTOL:
		blade = -deg_to_rad(6.0)
	q[CM.Bone.SPINE] = Quaternion(Vector3.UP, twist * 0.5) * Quaternion(swing, -lean) * Quaternion(Vector3.RIGHT, bend * 0.5 - back * 0.6)
	q[CM.Bone.CHEST] = Quaternion(Vector3.UP, twist * 0.5 + blade + deg_to_rad(4.0) * flinch + shake) \
			* Quaternion(Vector3.RIGHT, bend * 0.5 + breath - back * 0.4 + shake * 0.5)
	var gr: Array[Quaternion] = []
	var gp: Array[Vector3] = []
	_fk(r, q, hip_off, gr, gp)

	# head: look where asked (or ahead, steadied against the chest's twist), down when cowering
	var look: Vector3 = s.get("look", Vector3.ZERO)
	var head_g := Quaternion.IDENTITY
	if look.length_squared() > 0.5:
		var yaw := clampf(atan2(look.x, look.z), -deg_to_rad(70.0), deg_to_rad(70.0))
		var pitch := clampf(-asin(clampf(look.y, -1.0, 1.0)), -0.5, 0.5)
		head_g = Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch)
	match stance:
		Stance.CROUCH:
			head_g = head_g * Quaternion(Vector3.RIGHT, deg_to_rad(30.0))
		Stance.KNEEL:
			head_g = head_g * Quaternion(Vector3.RIGHT, deg_to_rad(15.0))
		Stance.PRONE:
			head_g = Quaternion(Vector3.UP, deg_to_rad(55.0))  # face turned to the side on the floor
		Stance.DEAD:
			head_g = Quaternion(Vector3.UP, deg_to_rad(-35.0)) * Quaternion(Vector3.FORWARD, deg_to_rad(10.0))
	head_g = head_g * Quaternion(Vector3.RIGHT, -deg_to_rad(float(pc["flinch_deg"])) * 0.6 * flinch) \
			* Quaternion(Vector3.UP, shake * 1.5)
	q[CM.Bone.HEAD] = gr[CM.Bone.CHEST].inverse() * head_g
	_fk(r, q, hip_off, gr, gp)

	# arms and the gear in the hands
	var gear: Dictionary = model.get("gear", {})
	var gun := gear.get("hand") as Node3D
	var gun_xf := Transform3D()
	if r["arms"]:
		var place := _arms(r, q, gr, gp, hold, s, pc, gun, amount, phase, run, dir, gait, t)
		_fk(r, q, hip_off, gr, gp)
		if gun != null:
			gun_xf = place if place != Transform3D() else _in_hand(r, gr, gp, 1, hold)

	# a new stance or hold blends in from the pose shown last; the gun stays in the right hand
	var key := stance * 100 + hold
	if int(model.get("key", key)) != key and model.has("shown_q"):
		model["from_q"] = (model["shown_q"] as Array).duplicate()
		model["from_hip"] = model["shown_hip"]
		model["blend"] = 0.0
	model["key"] = key
	var blend := minf(float(model.get("blend", 1.0)) + float(s.get("dt", 1.0)) / float(pc["blend_s"]), 1.0)
	model["blend"] = blend
	if blend < 1.0:
		var k := smoothstep(0.0, 1.0, blend)
		var from_q: Array = model["from_q"]
		var hand_target := _hand_frame(r, gr, gp, 1)
		for b in q.size():
			q[b] = (from_q[b] as Quaternion).slerp(q[b], k)
		hip_off = (model["from_hip"] as Vector3).lerp(hip_off, k)
		_fk(r, q, hip_off, gr, gp)
		gun_xf = _hand_frame(r, gr, gp, 1) * hand_target.affine_inverse() * gun_xf
	model["shown_q"] = q.duplicate()
	model["shown_hip"] = hip_off

	model.erase("muzzle")
	model.erase("light")
	if gun != null and r["arms"]:
		gun.transform = gun_xf
		if gun.has_meta("muzzle"):
			model["muzzle"] = Transform3D(gun_xf.basis, gun_xf * (gun.get_meta("muzzle") as Vector3))
		if gun.has_meta("light"):
			model["light"] = Transform3D(gun_xf.basis, gun_xf * (gun.get_meta("light") as Vector3))
	_place_worn(r, gear, gr, gp, h, hold)
	for b in q.size():
		sk.set_bone_pose_rotation(b, q[b])
	sk.set_bone_pose_position(CM.Bone.HIPS, (r["off"] as Array)[CM.Bone.HIPS] + hip_off)


## Angle (radians) for gait[key] = [walking, running] degrees at run 0..1.
static func _gait(gait: Dictionary, key: String, run: float) -> float:
	var a: Array = gait[key]
	return deg_to_rad(lerpf(float(a[0]), float(a[1]), run))


## What the poses need to know about a skeleton, read once: rest positions (local "off", global
## "rest"), parents, the arm and leg chains (rest directions and lengths), height and leg length.
static func _rig_info(sk: Skeleton3D) -> Dictionary:
	var n := sk.get_bone_count()
	var off: Array[Vector3] = []
	var rest: Array[Vector3] = []
	var parent: Array[int] = []
	for b in n:
		off.append(sk.get_bone_rest(b).origin)
		parent.append(sk.get_bone_parent(b))
		rest.append(off[b] + (rest[parent[b]] if parent[b] >= 0 else Vector3.ZERO))
	var r := {"off": off, "rest": rest, "parent": parent, "h": float(sk.get_meta("h", 1.75)),
			"leg_len": float(sk.get_meta("leg_len", 0.9)), "arms": bool(sk.get_meta("arms", false)),
			"profile": sk.get_meta("profile", {})}
	var arms: Array[Dictionary] = []
	for side in 2:  # 0 left (+X), 1 right
		var a := CM.Bone.UPPER_ARM_L if side == 0 else CM.Bone.UPPER_ARM_R
		var b := CM.Bone.FOREARM_L if side == 0 else CM.Bone.FOREARM_R
		var hand: Vector3 = sk.get_meta("hand_l" if side == 0 else "hand_r", rest[b] + Vector3(0, -0.3, 0))
		arms.append({"a": a, "b": b, "hand": hand, "ra": (rest[b] - rest[a]).normalized(), "rb": (hand - rest[b]).normalized(),
				"la": rest[a].distance_to(rest[b]), "lb": rest[b].distance_to(hand), "side": 1.0 if side == 0 else -1.0})
	r["arm"] = arms
	var legs: Array[Dictionary] = []
	for side in 2:
		var a := CM.Bone.THIGH_L if side == 0 else CM.Bone.THIGH_R
		var b := CM.Bone.SHIN_L if side == 0 else CM.Bone.SHIN_R
		var f := CM.Bone.FOOT_L if side == 0 else CM.Bone.FOOT_R
		legs.append({"a": a, "b": b, "f": f, "ra": (rest[b] - rest[a]).normalized(), "rb": (rest[f] - rest[b]).normalized(),
				"la": rest[a].distance_to(rest[b]), "lb": rest[b].distance_to(rest[f]), "side": 1.0 if side == 0 else -1.0})
	r["leg"] = legs
	return r


## Global rotations / positions of every bone from local rotations q and the hips' offset.
static func _fk(r: Dictionary, q: Array[Quaternion], hip_off: Vector3, gr: Array[Quaternion], gp: Array[Vector3]) -> void:
	var off: Array[Vector3] = r["off"]
	var parent: Array[int] = r["parent"]
	gr.resize(q.size())
	gp.resize(q.size())
	for b in q.size():
		var p := parent[b]
		if p < 0:
			gr[b] = q[b]
			gp[b] = off[b] + hip_off
		else:
			gr[b] = gr[p] * q[b]
			gp[b] = gp[p] + gr[p] * off[b]


## Rotation turning unit vector `from` onto `to` (the shortest way).
static func _arc(from: Vector3, to: Vector3) -> Quaternion:
	if from.dot(to) < -0.9999:
		var axis := from.cross(Vector3.RIGHT)
		if axis.length_squared() < 1e-6:
			axis = from.cross(Vector3.UP)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(from, to)


## Two-bone chain `c` (from _rig_info) rooted at `root`, its parent turned `pr`: the end reaches
## `target` (or as near as it can), the middle joint bending toward `pole`. Writes local rotations.
static func _ik(q: Array[Quaternion], c: Dictionary, pr: Quaternion, root: Vector3, target: Vector3, pole: Vector3) -> void:
	var la: float = c["la"]
	var lb: float = c["lb"]
	var d := target - root
	var dn := d.normalized() if d.length_squared() > 1e-8 else Vector3.DOWN
	var dist := clampf(d.length(), absf(la - lb) + 0.001, (la + lb) * 0.999)
	var cos_a := clampf((la * la + dist * dist - lb * lb) / (2.0 * la * dist), -1.0, 1.0)
	var across := pole - dn * pole.dot(dn)
	if across.length_squared() < 1e-6:
		across = dn.cross(Vector3.RIGHT)
	across = across.normalized()
	var mid := root + la * (dn * cos_a + across * sqrt(1.0 - cos_a * cos_a))
	_chain(q, c, pr, (mid - root).normalized(), (root + dn * dist - mid).normalized())


## Turns chain `c`'s forearm about its own length so the palm faces `want` (model space). The hands
## hang palms in at rest; the twist goes into the forearm, as a real one does.
static func _palm(q: Array[Quaternion], c: Dictionary, pr: Quaternion, want: Vector3) -> void:
	var fore: Quaternion = pr * q[c["a"]] * q[c["b"]]
	var along: Vector3 = fore * (c["rb"] as Vector3)
	var palm: Vector3 = fore * Vector3(-float(c["side"]), 0.0, 0.0)
	var a := (palm - along * palm.dot(along))
	var b := (want - along * want.dot(along))
	if a.length_squared() < 1e-6 or b.length_squared() < 1e-6:
		return
	var turn := a.normalized().signed_angle_to(b.normalized(), along)
	q[c["b"]] = q[c["b"]] * Quaternion(c["rb"], turn)


## Two-bone chain `c` pointed by direction: first segment along da, second along db (global).
static func _chain(q: Array[Quaternion], c: Dictionary, pr: Quaternion, da: Vector3, db: Vector3) -> void:
	var ga := _arc(c["ra"], da)
	var gb := _arc(ga * (c["rb"] as Vector3), db) * ga
	q[c["a"]] = pr.inverse() * ga
	q[c["b"]] = ga.inverse() * gb


## Legs and hips for the stance (the walk cycle when standing); returns the hips' offset.
static func _legs(r: Dictionary, q: Array[Quaternion], stance: int, amount: float, phase: float, run: float, dir: Vector3,
		gait: Dictionary, t: float) -> Vector3:
	var h: float = r["h"]
	var legs: Array[Dictionary] = r["leg"]
	var rest: Array[Vector3] = r["rest"]
	var hips: Vector3 = rest[CM.Bone.HIPS]
	match stance:
		Stance.STAND:
			var swing := Vector3(-dir.z, 0.0, dir.x)
			var thigh := _gait(gait, "thigh_deg", run) * amount * sin(phase)
			var knee := _gait(gait, "knee_deg", run) * amount
			var stance_knee := deg_to_rad(float(gait["stance_knee_deg"])) * amount
			var c := cos(phase)
			for leg in legs:
				var sign: float = leg["side"]
				q[leg["a"]] = Quaternion(swing, thigh * sign)
				# the knee bends most while that leg swings through (about +X a hanging shin goes back)
				q[leg["b"]] = Quaternion(Vector3.RIGHT, stance_knee + knee * maxf(c * sign, 0.0))
				q[leg["f"]] = (q[leg["a"]] * q[leg["b"]]).inverse().slerp(Quaternion.IDENTITY, 0.25)  # soles mostly flat
			# hips drop as the legs spread (the planted foot stays down) and sway a little standing
			var drop := float(r["leg_len"]) * (1.0 - cos(thigh)) * float(gait["hip_drop"])
			var sway := (sin(t * 0.7) * 0.007 + sin(t * 0.23) * 0.004) * h * (1.0 - amount)  # shifting weight from foot to foot
			return Vector3(sway, -drop, 0.0)
		Stance.CROUCH, Stance.KNEEL, Stance.WORK:
			var leg_len: float = legs[0]["la"]
			var low := 0.03 * h + leg_len  # knees on the floor: hips one thigh above them
			if stance == Stance.CROUCH:
				low = hips.y * 0.55
			var off := Vector3(0.0, low - hips.y, -0.04 * h if stance == Stance.CROUCH else 0.0)
			for leg in legs:
				var sign: float = leg["side"]
				var root: Vector3 = rest[leg["a"]] + off
				if stance == Stance.KNEEL or (stance == Stance.WORK and sign < 0.0):
					# knee down: thigh upright, shin back along the floor, toes pointing back
					q[leg["a"]] = Quaternion(Vector3.RIGHT, -deg_to_rad(8.0))
					q[leg["b"]] = Quaternion(Vector3.RIGHT, deg_to_rad(90.0))
					q[leg["f"]] = Quaternion(Vector3.RIGHT, deg_to_rad(100.0))
				else:
					# foot planted ahead (WORK, left) or under the body (CROUCH), knee out front
					var ankle: Vector3 = rest[leg["f"]]
					var ahead := (0.24 if stance == Stance.WORK else 0.04) * h
					var target := Vector3(ankle.x + sign * 0.02 * h, ankle.y, ankle.z + ahead)
					_ik(q, leg, Quaternion.IDENTITY, root, target, Vector3(sign * 0.25, 0.3, 1.0))
					q[leg["f"]] = (q[leg["a"]] * q[leg["b"]]).inverse()  # sole flat on the floor
			return off
		Stance.PRONE:  # face down, legs a little apart, toes in the floor
			for leg in legs:
				var sign: float = leg["side"]
				q[leg["a"]] = Quaternion(Vector3.BACK, sign * deg_to_rad(6.0))
				q[leg["f"]] = Quaternion(Vector3.RIGHT, deg_to_rad(35.0))
		Stance.DEAD:  # on the back, limp: one knee up, feet falling outward
			for leg in legs:
				var sign: float = leg["side"]
				q[leg["a"]] = Quaternion(Vector3.BACK, sign * deg_to_rad(9.0)) * Quaternion(Vector3.RIGHT, -deg_to_rad(25.0 if sign > 0.0 else 0.0))
				q[leg["b"]] = Quaternion(Vector3.RIGHT, deg_to_rad(40.0 if sign > 0.0 else 4.0))
				q[leg["f"]] = Quaternion(Vector3.UP, sign * deg_to_rad(30.0)) * Quaternion(Vector3.RIGHT, deg_to_rad(25.0))
	return Vector3.ZERO


## Arms for the hold. Returns where a gun held on the aim goes (skeleton space), or an empty
## Transform3D when the gun (if any) sits in the right hand as it hangs.
static func _arms(r: Dictionary, q: Array[Quaternion], gr: Array[Quaternion], gp: Array[Vector3], hold: int, s: Dictionary,
		pc: Dictionary, gun: Node3D, amount: float, phase: float, run: float, dir: Vector3, gait: Dictionary, t: float) -> Transform3D:
	var h: float = r["h"]
	var arms: Array[Dictionary] = r["arm"]
	var rest: Array[Vector3] = r["rest"]
	var chest := gr[CM.Bone.CHEST]
	var chest_at := gp[CM.Bone.CHEST]
	var to_chest := func(v: Vector3) -> Vector3: return chest_at + chest * (v - rest[CM.Bone.CHEST])  # rest point carried by the chest
	var recoil := float(s.get("recoil", 0.0))
	var reload := float(s.get("reload", -1.0))
	var out := Transform3D()
	var targets: Array = [null, null]  # per arm: [target, pole] or null (relaxed)
	match hold:
		Hold.RIFLE, Hold.PISTOL:
			var rifle := hold == Hold.RIFLE
			var basis := Basis.IDENTITY
			var sway := deg_to_rad(0.8) * amount
			basis = Basis(Vector3.UP, sin(phase) * sway) * Basis(Vector3.RIGHT, -deg_to_rad(float(pc["recoil_kick_deg"])) * recoil + cos(phase * 2.0) * sway)
			var at: Vector3
			if rifle:  # butt in the right shoulder pocket
				var pocket: Vector3 = to_chest.call(rest[CM.Bone.UPPER_ARM_R] + Vector3(0.035, -0.04, 0.055) * h)
				var stock: Vector3 = gun.get_meta("stock", Vector3(0, 0.06, -0.3)) if gun != null else Vector3(0, 0.06, -0.3)
				at = pocket - basis * stock
			else:  # both arms out, the pistol in front of the chest at shoulder height
				at = to_chest.call(Vector3(rest[CM.Bone.CHEST].x - 0.01 * h, rest[CM.Bone.UPPER_ARM_R].y - 0.05 * h, rest[CM.Bone.CHEST].z + 0.29 * h))
			at -= basis * Vector3(0, 0, 0.03 * recoil)
			if reload >= 0.0:  # tip the gun in, muzzle down a little, while the magazine changes
				var tip := sin(PI * clampf(reload, 0.0, 1.0))
				basis = basis * Basis(Vector3.BACK, deg_to_rad(28.0) * tip) * Basis(Vector3.RIGHT, deg_to_rad(14.0) * tip)
			out = Transform3D(basis, at)
			var fore: Vector3 = gun.get_meta("fore", Vector3(0.0, 0.03, 0.28)) if gun != null else Vector3(0.0, 0.03, 0.28)
			targets[1] = [out * Vector3.ZERO, Vector3(-0.6, -1.0, -0.2)]
			var support := out * fore
			if reload >= 0.0:  # support hand: magazine well -> pouch on the vest -> back
				var mag: Vector3 = gun.get_meta("mag", Vector3(0, -0.06, 0.1)) if gun != null else Vector3(0, -0.06, 0.1)
				var well := out * mag
				var pouch: Vector3 = to_chest.call(rest[CM.Bone.CHEST] + Vector3(0.06, -0.06, 0.1) * h)
				var k := clampf(reload, 0.0, 1.0)
				if k < 0.25:
					support = support.lerp(well, k / 0.25)
				elif k < 0.5:
					support = well.lerp(pouch, (k - 0.25) / 0.25)
				elif k < 0.8:
					support = pouch.lerp(well, (k - 0.5) / 0.3)
				else:
					support = well.lerp(support, (k - 0.8) / 0.2)
			targets[0] = [support, Vector3(0.5, -1.0, 0.0)]
		Hold.PISTOL_ONE:  # one arm out toward the aim
			var aim: Vector3 = s.get("aim", Vector3.BACK)
			var shoulder := gp[CM.Bone.UPPER_ARM_R]
			var c: Dictionary = arms[1]
			var reach: float = (float(c["la"]) + float(c["lb"])) * 0.93
			var grip := shoulder + aim * reach + Vector3(0, -0.02 * h, 0)
			var basis := Basis.looking_at(-aim, Vector3.UP) * Basis(Vector3.RIGHT, -deg_to_rad(float(pc["recoil_kick_deg"])) * 1.5 * recoil)
			out = Transform3D(basis, grip)
			targets[1] = [grip, Vector3(-0.5, -1.0, 0.0)]
		Hold.WORK:  # both hands forward at chest height (lock, cuffs, camera)
			for i in 2:
				var sign: float = arms[i]["side"]
				targets[i] = [Vector3(rest[CM.Bone.CHEST].x + sign * 0.05 * h, gp[CM.Bone.CHEST].y - 0.04 * h, gp[CM.Bone.CHEST].z + 0.24 * h),
						Vector3(sign * 0.6, -1.0, 0.0)]
		Hold.CUFFED:  # wrists together behind the lower back
			for i in 2:
				var sign: float = arms[i]["side"]
				targets[i] = [gp[CM.Bone.SPINE] + Vector3(sign * 0.025 * h, -0.03 * h, -0.1 * h), Vector3(sign * 0.6, -0.4, -1.0)]
		Hold.COVER:  # hands over the head, elbows out
			var head := gp[CM.Bone.HEAD]
			var hb := Basis(gr[CM.Bone.HEAD])
			for i in 2:
				var sign: float = arms[i]["side"]
				targets[i] = [head + hb * (Vector3(sign * 0.045, 0.1, 0.0) * h), Vector3(sign, 0.1, 0.6)]
		Hold.HANDS_HEAD:  # fingers laced behind the head
			var head := gp[CM.Bone.HEAD]
			var hb := Basis(gr[CM.Bone.HEAD])
			for i in 2:
				var sign: float = arms[i]["side"]
				targets[i] = [head + hb * (Vector3(sign * 0.025, 0.075, -0.06) * h), Vector3(sign, 0.3, -0.3)]
		Hold.STARTLED:  # hands up in front of the chest, palms out
			for i in 2:
				var sign: float = arms[i]["side"]
				targets[i] = [to_chest.call(Vector3(rest[CM.Bone.CHEST].x + sign * 0.07 * h, rest[CM.Bone.CHEST].y + 0.06 * h, rest[CM.Bone.CHEST].z + 0.14 * h)),
						Vector3(sign, -1.0, -0.2)]
		Hold.HANDS_UP:  # surrender: hands up beside the head, elbows out and down
			var lift := float(pc["hands_up_lift"])
			for i in 2:
				var sign: float = arms[i]["side"]
				var shoulder: Vector3 = rest[arms[i]["a"]]
				targets[i] = [to_chest.call(Vector3(shoulder.x + sign * 0.02 * h, shoulder.y + lift * h, shoulder.z + 0.03 * h)),
						Vector3(sign, -0.5, -0.1)]
	for i in 2:
		var c: Dictionary = arms[i]
		var root := gp[c["a"]]
		if targets[i] != null:
			_ik(q, c, chest, root, targets[i][0], (targets[i][1] as Vector3).normalized())
			if hold == Hold.HANDS_UP or hold == Hold.STARTLED:
				_palm(q, c, chest, Vector3.BACK)  # show the palms
			continue
		# relaxed: hanging a little out from the body, swinging against the legs, elbows bending
		# more the faster it goes; the right arm a bit forward with a pistol in it
		var sign: float = c["side"]
		var swing := _gait(gait, "arm_deg", run) * dir.z * amount * sin(phase) * sign
		var idle := sin(t * 0.9 + sign) * deg_to_rad(1.5) * (1.0 - amount)
		var forward := deg_to_rad(12.0) if hold == Hold.PISTOL_LOW and sign < 0.0 else 0.0
		var upper := Quaternion(Vector3.RIGHT, swing - forward + idle) * Vector3(sign * 0.14, -1.0, 0.0).normalized()
		var elbow := deg_to_rad(lerpf(12.0, 85.0, run * amount) + (25.0 if hold == Hold.PISTOL_LOW and sign < 0.0 else 0.0))
		var lower := Quaternion(Vector3.RIGHT, swing - forward + idle - elbow) * Vector3(sign * 0.05, -1.0, 0.0).normalized()
		_chain(q, c, chest, upper, lower)
	return out


## Hand `side` (0 left, 1 right) as a frame: at the hand's centre, turned with the forearm.
static func _hand_frame(r: Dictionary, gr: Array[Quaternion], gp: Array[Vector3], side: int) -> Transform3D:
	var c: Dictionary = (r["arm"] as Array)[side]
	var fore := gr[c["b"]]
	return Transform3D(Basis(fore), gp[c["b"]] + fore * ((c["hand"] as Vector3) - (r["rest"] as Array)[c["b"]]))


## Where gear in hand `side` (0 left, 1 right) sits: at the hand; a gun hanging with the arm points
## forward and down, a door camera held out while working points ahead, level with the body.
static func _in_hand(r: Dictionary, gr: Array[Quaternion], gp: Array[Vector3], side: int, hold: int) -> Transform3D:
	var c: Dictionary = (r["arm"] as Array)[side]
	var elbow_rest: Vector3 = (r["rest"] as Array)[c["b"]]
	var fore := gr[c["b"]]
	var hand := gp[c["b"]] + fore * ((c["hand"] as Vector3) - elbow_rest)
	if hold == Hold.WORK:
		return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(10.0)), hand)
	return Transform3D(Basis(fore) * Basis(Vector3.RIGHT, deg_to_rad(60.0)), hand)


## Gear worn on the body: slung rifle (back, or in front while working), holstered pistol on the
## right thigh, cuffs between the wrists, cap on the head, armband on the left upper arm; and what
## people wear (sized from the body profile found at load): "hat" (beanie), "eyes" (glasses),
## "mask" (bandana) on the head, "pack" (backpack) on the back, "radio" on the chest, "patch" on the
## right upper arm.
static func _place_worn(r: Dictionary, gear: Dictionary, gr: Array[Quaternion], gp: Array[Vector3], h: float, hold: int) -> void:
	var rest: Array[Vector3] = r["rest"]
	var chest := Transform3D(Basis(gr[CM.Bone.CHEST]), gp[CM.Bone.CHEST])
	var chest_rest := rest[CM.Bone.CHEST]
	var back := gear.get("back") as Node3D
	if back != null:
		if hold == Hold.WORK:  # hanging on its sling in front, muzzle down
			back.transform = chest * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(75.0)) * Basis(Vector3.BACK, deg_to_rad(25.0)),
					Vector3(0.0, -0.02 * h, 0.1 * h))
		else:  # across the back, muzzle up over the left shoulder
			back.transform = chest * Transform3D(Basis(Vector3.BACK, deg_to_rad(35.0)) * Basis(Vector3.RIGHT, -deg_to_rad(90.0)),
					Vector3(0.02 * h, -0.05 * h, -0.09 * h))
	var holster := gear.get("holster") as Node3D
	if holster != null:
		var thigh := Transform3D(Basis(gr[CM.Bone.THIGH_R]), gp[CM.Bone.THIGH_R])
		holster.transform = thigh * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(-0.055 * h, -0.07 * h, 0.0))
	var arms: Array[Dictionary] = r["arm"]
	var cuffs := gear.get("cuffs") as Node3D
	if cuffs != null and r["arms"]:
		var wrists: Array[Vector3] = []
		for c in arms:
			var elbow := gp[c["b"]]
			var hand := elbow + gr[c["b"]] * ((c["hand"] as Vector3) - rest[c["b"]])
			wrists.append(hand.lerp(elbow, 0.25))
		var across := (wrists[0] - wrists[1])
		cuffs.transform = Transform3D(Basis(_arc(Vector3.RIGHT, across.normalized())), (wrists[0] + wrists[1]) * 0.5)
	var cap := gear.get("cap") as Node3D
	if cap != null:
		cap.transform = Transform3D(Basis(gr[CM.Bone.HEAD]), gp[CM.Bone.HEAD]) * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.092 * h, 0.006 * h))
	var band := gear.get("band") as Node3D
	if band != null:
		var c: Dictionary = arms[0]
		if r["arms"]:
			var along: Vector3 = gr[c["a"]] * (c["ra"] as Vector3)
			band.transform = Transform3D(Basis(_arc(Vector3.DOWN, along)), gp[c["a"]] + along * float(c["la"]) * 0.4)
		else:  # hands-up model: its left upper arm rises from the shoulder, out and up
			band.transform = chest * Transform3D(Basis(_arc(Vector3.UP, Vector3(0.35, 1.0, 0.0).normalized())),
					rest[c["a"]] - chest_rest + Vector3(0.025, 0.06, 0.0) * h)
	_place_wear(r, gear, gr, gp, h, chest)


## Hat, glasses and bandana are built to a unit head: here scaled to this head (its width,
## height and depth from the profile) and carried by the head bone; the backpack and radio by the
## chest, the patch by the right upper arm.
static func _place_wear(r: Dictionary, gear: Dictionary, gr: Array[Quaternion], gp: Array[Vector3], h: float, chest: Transform3D) -> void:
	var prof: Dictionary = r["profile"]
	if prof.is_empty():
		return
	var rest: Array[Vector3] = r["rest"]
	var gx := float(prof["gx"])
	var head_bone := Transform3D(Basis(gr[CM.Bone.HEAD]), gp[CM.Bone.HEAD]) * Transform3D(Basis.IDENTITY, -rest[CM.Bone.HEAD])
	var size := Vector3(maxf(float(prof["head_half"]) * 2.0, 0.08 * h), 0.135 * h, maxf(float(prof["face_z"]) - float(prof["head_back"]), 0.1 * h))
	var head := head_bone * Transform3D(Basis.from_scale(size),
			Vector3(gx, float(prof["head_top"]) - size.y * 0.5, (float(prof["face_z"]) + float(prof["head_back"])) * 0.5))
	for slot: String in ["hat", "mask"]:
		var g := gear.get(slot) as Node3D
		if g != null:
			g.transform = head
	var eyes := gear.get("eyes") as Node3D
	if eyes != null:
		eyes.transform = head * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.07, 0.43))  # on the nose bridge (the nose tip is at 0.5)
	var torso := func(y: float, side: String) -> float:  # the profile's front / back z at height y (share of h)
		var arr: PackedFloat32Array = prof[side]
		return arr[clampi(int((y - float(prof["y0"])) / float(prof["dy"])), 0, arr.size() - 1)]
	var chest_bone := chest * Transform3D(Basis.IDENTITY, -rest[CM.Bone.CHEST])
	var pack := gear.get("pack") as Node3D
	if pack != null:
		pack.transform = chest_bone * Transform3D(Basis.IDENTITY, Vector3(gx, 0.66 * h, torso.call(0.66, "back") + 0.015 * h))  # snug: into the cloth a little
	var radio := gear.get("radio") as Node3D
	if radio != null:
		radio.transform = chest_bone * Transform3D(Basis(Vector3.BACK, deg_to_rad(-8.0)), Vector3(gx - 0.075 * h, 0.755 * h, torso.call(0.755, "front") + 0.012 * h))
	var patch := gear.get("patch") as Node3D
	if patch != null and r["arms"]:
		var c: Dictionary = (r["arm"] as Array)[1]  # the right arm (the officer model wears its own badge on the left)
		var ra: Vector3 = c["ra"]
		var out := ra.cross(Vector3.BACK).normalized()  # away from the body, square to the arm
		var at: Vector3 = rest[c["a"]] + ra * float(c["la"]) * 0.32 + out * 0.03 * h
		var basis := Basis.looking_at(-out, -ra)  # its face (+Z) outward, its top up the arm
		patch.transform = Transform3D(Basis(gr[c["a"]]) * basis, gp[c["a"]] + gr[c["a"]] * (at - rest[c["a"]]))
