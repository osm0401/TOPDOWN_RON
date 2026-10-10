class_name RoomCode
extends RefCounted
## IPv4 + port <-> 12-char Crockford Base32 room code ("XXXX-XXXX-XXXX").
## Payload: 4 IP bytes + 2 port bytes + CRC8 = 56 bits, padded with 4 zero bits.

const ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const CODE_CHARS := 12


static func _crc8(bytes: PackedByteArray) -> int:
	var crc := 0
	for b in bytes:
		crc ^= b
		for _i in 8:
			if crc & 0x80:
				crc = ((crc << 1) ^ 0x07) & 0xFF
			else:
				crc = (crc << 1) & 0xFF
	return crc


## Returns "" when ip/port are invalid.
static func encode(ip: String, port: int) -> String:
	var parts := ip.split(".")
	if parts.size() != 4 or port < 1 or port > 65535:
		return ""
	var bytes := PackedByteArray()
	for p in parts:
		if not p.is_valid_int():
			return ""
		var v := int(p)
		if v < 0 or v > 255:
			return ""
		bytes.append(v)
	bytes.append((port >> 8) & 0xFF)
	bytes.append(port & 0xFF)
	bytes.append(_crc8(bytes))
	var n := 0
	for b in bytes:
		n = (n << 8) | b
	n <<= 4
	var out := ""
	for i in CODE_CHARS:
		out += ALPHABET[(n >> (5 * (CODE_CHARS - 1 - i))) & 31]
		if i % 4 == 3 and i != CODE_CHARS - 1:
			out += "-"
	return out


## Returns {"ok": bool, "ip": String, "port": int}.
static func decode(code: String) -> Dictionary:
	var fail := {"ok": false, "ip": "", "port": 0}
	var s := code.to_upper().replace("-", "").replace(" ", "")
	s = s.replace("O", "0").replace("I", "1").replace("L", "1")
	if s.length() != CODE_CHARS:
		return fail
	var n := 0
	for c in s:
		var v := ALPHABET.find(c)
		if v < 0:
			return fail
		n = (n << 5) | v
	if n & 0xF != 0:
		return fail
	n >>= 4
	var bytes := PackedByteArray()
	for i in 7:
		bytes.append((n >> (8 * (6 - i))) & 0xFF)
	var crc := bytes[6]
	bytes.resize(6)
	if _crc8(bytes) != crc:
		return fail
	return {
		"ok": true,
		"ip": "%d.%d.%d.%d" % [bytes[0], bytes[1], bytes[2], bytes[3]],
		"port": (bytes[4] << 8) | bytes[5],
	}


## First address in the Tailscale CGNAT range 100.64.0.0/10, or "" if none.
static func pick_vlan_ip(addresses: PackedStringArray) -> String:
	for a in addresses:
		var p := a.split(".")
		if p.size() == 4 and p[0] == "100" and p[1].is_valid_int():
			var second := int(p[1])
			if second >= 64 and second <= 127:
				return a
	return ""
