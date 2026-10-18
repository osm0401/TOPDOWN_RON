extends RefCounted
## Night rain over the ground outside the building (data/view3d.json "weather"): falling streaks
## and small splashes where they land. Drops start only above open ground, never above the
## building (it has no drawn roof), and fall straight down, so none land in a room. The streaks
## are lit like everything else: they show in the street lamps' light and fade in the dark. The
## wet ground itself (darker, glossy, puddles with rings) is the surface shader's `wet` / `puddles`.
## No class_name: preloaded (see world_view_3d.gd).


## Builds the rain under `parent` (positions in meters, the map's px times k). Returns {"drops",
## "splashes"} (GPUParticles3D) or {} when the weather has no rain.
static func build(parent: Node3D, bounds: Rect2, building: Rect2, k: float, cfg: Dictionary) -> Dictionary:
	var rc: Dictionary = cfg.get("rain", {})
	if rc.is_empty() or not bool(rc.get("on", true)):
		return {}
	var height := float(rc["height_m"])
	var speed := float(rc["fall_m_s"])
	var spots := _open_ground(bounds, building, k, int(rc.get("spots", 4096)))
	var drops := GPUParticles3D.new()
	drops.name = "rain"
	drops.amount = int(rc["drops"])
	drops.lifetime = height / speed
	drops.preprocess = drops.lifetime  # already raining on the first frame
	drops.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	drops.visibility_aabb = AABB(Vector3(bounds.position.x * k, -1.0, bounds.position.y * k), Vector3(bounds.size.x * k, height + 2.0, bounds.size.y * k))
	drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	pm.emission_point_texture = _points_texture(spots, height)
	pm.emission_point_count = spots.size()
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 0.0
	pm.initial_velocity_min = speed
	pm.initial_velocity_max = speed
	pm.gravity = Vector3.ZERO
	drops.process_material = pm
	var streak := QuadMesh.new()
	streak.size = Vector2(float(rc["width_m"]), float(rc["length_m"]))
	streak.material = _drop_material(rc)
	drops.draw_pass_1 = streak
	parent.add_child(drops)
	var splashes := GPUParticles3D.new()
	splashes.name = "splashes"
	splashes.amount = int(rc["splashes"])
	splashes.lifetime = 0.22
	splashes.preprocess = splashes.lifetime
	splashes.visibility_aabb = drops.visibility_aabb
	splashes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := ParticleProcessMaterial.new()
	sm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	sm.emission_point_texture = _points_texture(spots, 0.02)
	sm.emission_point_count = spots.size()
	sm.direction = Vector3(0, 1, 0)
	sm.spread = 70.0
	sm.initial_velocity_min = 0.3
	sm.initial_velocity_max = 0.8
	sm.gravity = Vector3(0, -9.8, 0)
	sm.scale_min = 0.6
	sm.scale_max = 1.2
	var fade := Gradient.new()  # a quick bright fleck that fades
	fade.set_color(0, Color(1, 1, 1, 0.9))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade
	sm.color_ramp = fade_tex
	splashes.process_material = sm
	var fleck := QuadMesh.new()
	fleck.size = Vector2(0.035, 0.035)
	var fm := _drop_material(rc)
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	fm.vertex_color_use_as_albedo = true
	fleck.material = fm
	splashes.draw_pass_1 = fleck
	parent.add_child(splashes)
	return {"drops": drops, "splashes": splashes}


## Random spots on the open ground: inside bounds, outside the building (and a little away from
## its walls, so no streak is drawn over a wall top). Always the same for the same map.
static func _open_ground(bounds: Rect2, building: Rect2, k: float, count: int) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var keep_out := building.grow(10.0)
	var out := PackedVector2Array()
	var tries := 0
	while out.size() < count and tries < count * 20:
		tries += 1
		var p := Vector2(rng.randf_range(bounds.position.x, bounds.end.x), rng.randf_range(bounds.position.y, bounds.end.y))
		if not keep_out.has_point(p):
			out.append(p * k)
	return out


static func _points_texture(spots: PackedVector2Array, y: float) -> ImageTexture:
	var img := Image.create(spots.size(), 1, false, Image.FORMAT_RGBF)
	for i in spots.size():
		img.set_pixel(i, 0, Color(spots[i].x, y, spots[i].y))
	return ImageTexture.create_from_image(img)


## Lit, see-through and a little glossy: a streak shows where a lamp lights it.
static func _drop_material(rc: Dictionary) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var c: Array = rc["color"]
	m.albedo_color = Color(float(c[0]), float(c[1]), float(c[2]), float(rc["alpha"]))
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.2
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true  # a faint sheen even away from the lamps, so the rain still reads
	m.emission = Color(float(c[0]), float(c[1]), float(c[2]))
	m.emission_energy_multiplier = float(rc.get("glow", 0.05))
	return m
