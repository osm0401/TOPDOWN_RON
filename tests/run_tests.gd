extends SceneTree
## Headless test runner (no addons):
## Godot_console.exe --headless --path D:\TOPDOWNRON --script tests/run_tests.gd

var _failed := 0


func _init() -> void:
	_test_room_code()
	_test_classify_ip()
	print("---- %s" % ("FAILED: %d" % _failed if _failed > 0 else "ALL PASSED"))
	quit(1 if _failed > 0 else 0)


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
