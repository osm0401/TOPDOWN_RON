class_name UpnpHelper
extends RefCounted
## Opens/closes a UDP port on the home router via UPnP (blocking: run it in a Thread).
## Result error keys: no_gateway, no_external_ip, private (double NAT), cgnat, map_failed.

const DISCOVER_TIMEOUT_MS := 2000
const DISCOVER_TTL := 2
const DESCRIPTION := "TOPDOWNRON"


## "public", "private", "cgnat" (100.64/10) or "invalid".
static func classify_ip(ip: String) -> String:
	var p := ip.split(".")
	if p.size() != 4:
		return "invalid"
	var o: Array[int] = []
	for x in p:
		if not x.is_valid_int() or int(x) < 0 or int(x) > 255:
			return "invalid"
		o.append(int(x))
	if o[0] == 0 or o[0] == 10 or o[0] == 127:
		return "private"
	if o[0] == 172 and o[1] >= 16 and o[1] <= 31:
		return "private"
	if o[0] == 192 and o[1] == 168:
		return "private"
	if o[0] == 169 and o[1] == 254:
		return "private"
	if o[0] == 100 and o[1] >= 64 and o[1] <= 127:
		return "cgnat"
	return "public"


## Returns {"ok": bool, "ip": String, "upnp": UPNP, "error": String, "code": int}.
static func open_port(port: int, lease_s: int) -> Dictionary:
	var upnp := UPNP.new()
	var err := upnp.discover(DISCOVER_TIMEOUT_MS, DISCOVER_TTL, "InternetGatewayDevice")
	var gw := upnp.get_gateway()
	if err != UPNP.UPNP_RESULT_SUCCESS or gw == null or not gw.is_valid_gateway():
		return _fail("no_gateway", "", err)
	var ip := upnp.query_external_address()
	var kind := classify_ip(ip)
	if kind == "invalid":
		return _fail("no_external_ip", ip)
	if kind != "public":
		return _fail(kind, ip)
	var res := upnp.add_port_mapping(port, port, DESCRIPTION, "UDP", lease_s)
	if res == UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
		res = upnp.add_port_mapping(port, port, DESCRIPTION, "UDP", 0)
	if res != UPNP.UPNP_RESULT_SUCCESS:
		return _fail("map_failed", ip, res)
	return {"ok": true, "ip": ip, "upnp": upnp, "error": "", "code": 0}


static func close_port(upnp: UPNP, port: int) -> void:
	if upnp != null:
		upnp.delete_port_mapping(port, "UDP")


static func _fail(error: String, ip: String = "", code: int = 0) -> Dictionary:
	return {"ok": false, "ip": ip, "upnp": null, "error": error, "code": code}
