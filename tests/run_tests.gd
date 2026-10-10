extends SceneTree
## Headless test runner (no addons):
## Godot_console.exe --headless --path D:\TOPDOWNRON --script tests/run_tests.gd

const PLAYER_R := 14.0
var _failed := 0


func _initialize() -> void:
	_test_room_code()
	_test_classify_ip()
	_test_weapon()
	await _test_level()
	print("---- %s" % ("FAILED: %d" % _failed if _failed > 0 else "ALL PASSED"))
	quit(1 if _failed > 0 else 0)


func _test_weapon() -> void:
	var w := WeaponState.create(3, 2, 0.25, 1.0)
	_check(w.current == 3 and str(w.spares) == "[3, 3]", "weapon starts full with spare mags")
	_check(w.try_fire() and w.current == 2, "fire uses one round")
	_check(not w.try_fire(), "fire interval blocks immediate refire")
	w.update(0.3)
	_check(w.try_fire() and w.current == 1, "fire again after interval")
	_check(w.start_reload(), "reload starts when a fuller spare exists")
	_check(not w.try_fire(), "cannot fire while reloading")
	_check(not w.update(0.5) and w.reloading, "reload not finished yet")
	_check(w.update(0.6) and not w.reloading, "reload finished")
	_check(w.current == 3 and str(w.spares) == "[1, 3]", "old magazine keeps its remaining rounds")
	var packed := w.to_packed()
	var copy := WeaponState.new()
	copy.from_packed(packed)
	_check(copy.current == 3 and str(copy.spares) == "[1, 3]" and not copy.reloading, "pack/unpack roundtrip")
	var empty := WeaponState.create(2, 1, 0.0, 0.5)
	empty.try_fire()
	empty.try_fire()
	_check(not empty.try_fire(), "empty magazine cannot fire")
	empty.start_reload()
	empty.update(0.6)
	empty.try_fire()
	empty.try_fire()
	empty.update(0.0)
	_check(not empty.start_reload(), "no reload when spares are not fuller")


func _test_level() -> void:
	var lv := Level.new()
	_check(lv.load_map("res://data/map_01.json"), "map loads")
	root.add_child(lv)
	await physics_frame
	await physics_frame
	# door B (index 1) is in the corridor-north wall at x 780..860
	var a := Vector2(820, 500)
	var b := Vector2(820, 300)
	_check(not lv.has_los(a, b), "closed door blocks line of sight")
	_check(not lv.has_los(Vector2(300, 500), Vector2(300, 300)), "wall blocks line of sight")
	_check(lv.has_los(Vector2(300, 500), Vector2(1300, 500)), "corridor is clear")
	lv.toggle_door(1, 1)
	await physics_frame
	await physics_frame
	_check(lv.has_los(a, b), "open door lets sight through")
	_check(lv.door_actor[1] == 1, "door remembers who toggled it")

	var poly_open := lv.visibility_polygon(a, 700.0)
	_check(_min_y(poly_open) < 430.0, "open door: fog polygon reaches into the room")
	lv.toggle_door(1, 2)
	await physics_frame
	await physics_frame
	var poly_closed := lv.visibility_polygon(a, 700.0)
	_check(_min_y(poly_closed) >= 430.0, "closed door: fog polygon stays in the corridor")

	var near := lv.nearest_door(Vector2(150, 480), 80.0)
	_check(near == 5, "entrance door is nearest from the spawn")
	_check(lv.nearest_door(Vector2(700, 500), 30.0) == -1, "no door in range in mid corridor")
	lv.toggle_door(4, 1)
	var packed := lv.pack_doors()
	var lv2 := Level.new()
	lv2.load_map("res://data/map_01.json")
	lv2.unpack_doors(packed)
	_check(lv2.is_door_open(4) and not lv2.is_door_open(1) and lv2.door_actor[4] == 1, "door state pack/unpack")

	var body := CharacterBody2D.new()
	body.collision_layer = 2
	body.collision_mask = Level.WALL_LAYER
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.position = Vector2(300, 500)
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = PLAYER_R
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)
	for i in 60:
		body.velocity = Vector2(0, -220)
		body.move_and_slide()
		await physics_frame
	_check(body.position.y >= 450.0 + PLAYER_R - 1.0, "player cannot walk through a wall (y=%.1f)" % body.position.y)
	body.position = Vector2(150, 500)
	for i in 30:
		body.velocity = Vector2(220, 0)
		body.move_and_slide()
		await physics_frame
	_check(body.position.x <= 200.0 - PLAYER_R + 1.0, "closed entrance door blocks the player (x=%.1f)" % body.position.x)
	lv.toggle_door(5, 1)
	await physics_frame
	await physics_frame
	for i in 30:
		body.velocity = Vector2(220, 0)
		body.move_and_slide()
		await physics_frame
	_check(body.position.x > 230.0, "open entrance door lets the player in (x=%.1f)" % body.position.x)


func _min_y(poly: PackedVector2Array) -> float:
	var m := INF
	for p in poly:
		m = minf(m, p.y)
	return m


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failed += 1


func _test_classify_ip() -> void:
	var expect := {
		"203.0.113.5": "public", "8.8.8.8": "public", "100.63.0.1": "public", "100.128.0.1": "public",
		"192.168.0.1": "private", "10.1.2.3": "private", "172.16.0.1": "private", "172.31.9.9": "private",
		"172.32.0.1": "public", "127.0.0.1": "private", "169.254.1.1": "private",
		"100.64.0.1": "cgnat", "100.127.255.255": "cgnat",
		"": "invalid", "1.2.3": "invalid", "300.1.1.1": "invalid", "a.b.c.d": "invalid",
	}
	for ip in expect:
		_check(UpnpHelper.classify_ip(ip) == expect[ip], "classify_ip '%s' -> %s" % [ip, expect[ip]])


func _test_room_code() -> void:
	var cases := [["100.64.0.1", 24565], ["127.0.0.1", 1], ["255.255.255.255", 65535], ["0.0.0.0", 80]]
	for c in cases:
		var code := RoomCode.encode(c[0], c[1])
		_check(code.length() == 14, "encode format %s:%d -> %s" % [c[0], c[1], code])
		var d := RoomCode.decode(code)
		_check(d.ok and d.ip == c[0] and d.port == c[1], "roundtrip %s:%d" % [c[0], c[1]])

	var code := RoomCode.encode("100.101.102.103", 24565)
	var lower := code.to_lower().replace("-", "")
	_check(RoomCode.decode(lower).ok, "decode ignores case and hyphens")
	_check(RoomCode.decode(" " + code + " ").ok, "decode ignores spaces")

	var undetected := 0
	var raw := code.replace("-", "")
	for i in raw.length():
		for ch in RoomCode.ALPHABET:
			if ch == raw[i]:
				continue
			var bad := raw.substr(0, i) + ch + raw.substr(i + 1)
			if RoomCode.decode(bad).ok:
				undetected += 1
	_check(undetected == 0, "every single-char typo is rejected (undetected=%d)" % undetected)

	_check(not RoomCode.decode("").ok, "empty code rejected")
	_check(not RoomCode.decode("ABCD-EFGH").ok, "short code rejected")
	_check(not RoomCode.decode("UUUU-UUUU-UUUU").ok, "invalid chars rejected")
	_check(RoomCode.encode("256.1.1.1", 80) == "", "bad octet rejected")
	_check(RoomCode.encode("1.2.3", 80) == "", "bad ip shape rejected")
	_check(RoomCode.encode("1.2.3.4", 0) == "", "port 0 rejected")
	_check(RoomCode.encode("1.2.3.4", 65536) == "", "port 65536 rejected")

	var addrs := PackedStringArray(["192.168.0.5", "fe80::1", "100.63.1.1", "100.100.5.9", "100.128.0.1"])
	_check(RoomCode.pick_vlan_ip(addrs) == "100.100.5.9", "pick_vlan_ip picks 100.64/10 only")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["10.0.0.2"])) == "", "pick_vlan_ip empty when none")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["192.168.45.79", "26.215.124.50"])) == "26.215.124.50", "pick_vlan_ip finds Radmin 26.x")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["25.1.2.3"])) == "25.1.2.3", "pick_vlan_ip finds Hamachi 25.x")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["26.1.1.1", "100.100.5.9", "25.1.1.1"])) == "100.100.5.9", "Tailscale preferred over Radmin/Hamachi")
	_check(RoomCode.pick_vlan_ip(PackedStringArray(["25.1.1.1", "26.1.1.1"])) == "26.1.1.1", "Radmin preferred over Hamachi")
	_check(RoomCode.vlan_kind("27.0.0.1") == "" and RoomCode.vlan_kind("x.y") == "", "vlan_kind ignores other ranges")
