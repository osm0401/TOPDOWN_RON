extends SceneTree
## Checks whether this PC's router supports UPnP: opens the game port, reports, closes it again.
## Godot_console.exe --headless --path D:\TOPDOWNRON --script tests/upnp_probe.gd
## The public IP is not printed (only its class), so the output is safe to share.


func _init() -> void:
	var port := int(JsonData.load_dict("res://data/net.json").get("port", 0))
	print("probing UPnP, port=%d ..." % port)
	var r := UpnpHelper.open_port(port, 60)
	if r.ok:
		print("RESULT ok: gateway answered, public address class=%s, mapping created" % UpnpHelper.classify_ip(r.ip))
		UpnpHelper.close_port(r.upnp, port)
		print("mapping closed")
		quit(0)
	else:
		print("RESULT fail: error=%s upnp_code=%d address_class=%s" % [r.error, r.code, UpnpHelper.classify_ip(r.ip)])
		quit(1)
