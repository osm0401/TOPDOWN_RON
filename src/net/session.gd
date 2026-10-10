extends Node
## Autoload "Session": connection setup only (ENet host/join, address discovery, net log).
## Game state sync lives in NetWorld, so this file is the only thing to swap for Relay/Steam.
##
## Host address priority: VPN address (Tailscale) > UPnP public address > local only.

signal hosted(code: String)
signal client_connected
signal join_failed(reason: String)
signal connection_lost(reason: String)

const UPNP_LEASE_S := 3600

var cfg: Dictionary = {}
var is_hosting := false
var room_code := ""      ## "" while the address is still being resolved
var route := ""          ## "vpn" | "upnp" | "local" (valid once room_code is set)
var host_note := ""      ## status / warning text for the host HUD
var solo := false         ## single player: no network peer, the second officer is absent
var solo_loadout := {"primary": "rifle_lethal", "tools": ["lockpick", "taser"]}
var difficulty := "normal"  ## preset key in data/difficulty.json (only the host's value matters)

var _log: FileAccess
var _thread: Thread
var _upnp_gen := 0
var _upnp: UPNP
var _mapped_port := 0


func _ready() -> void:
	cfg = JsonData.load_dict("res://data/net.json")
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	multiplayer.peer_disconnected.connect(_on_peer_gone)


func _exit_tree() -> void:
	leave()


## Opens a room (1 client max). Returns false if the server could not start.
## The room code may arrive later (UPnP): watch `hosted` / `room_code`.
func host(force_local: bool = false) -> bool:
	leave()
	var port := int(cfg.get("port", 0))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 1)
	_open_log("host")
	if err != OK:
		log_line("host failed port=%d: %s" % [port, error_string(err)])
		return false
	multiplayer.multiplayer_peer = peer
	is_hosting = true
	if force_local:
		_finish_host("127.0.0.1", "local", "")
		return true
	var vpn_ip := RoomCode.pick_vlan_ip(IP.get_local_addresses())
	if vpn_ip != "":
		_finish_host(vpn_ip, "vpn", tr("VPN 주소 사용: %s") % RoomCode.vlan_kind(vpn_ip))
		return true
	host_note = tr("공유기에 포트를 여는 중...")
	log_line("no VPN address, trying UPnP")
	_upnp_gen += 1
	_thread = Thread.new()
	_thread.start(_upnp_worker.bind(_upnp_gen, port))
	return true


## Single player: same world and rules, no connection. The second officer does not exist.
func start_solo() -> void:
	leave()
	_open_log("solo")
	solo = true
	is_hosting = true
	log_line("solo game")


func join(code: String) -> bool:
	leave()
	var d := RoomCode.decode(code)
	if not d.ok:
		join_failed.emit(tr("방 코드가 올바르지 않습니다"))
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(d.ip, d.port)
	if err != OK:
		join_failed.emit(tr("접속할 수 없습니다"))
		return false
	multiplayer.multiplayer_peer = peer
	_open_log("client")
	log_line("joining %s:%d" % [d.ip, d.port])
	get_tree().create_timer(float(cfg.get("connect_timeout_s", 5.0))).timeout.connect(_on_join_timeout.bind(peer))
	return true


func leave() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_upnp_gen += 1
	_close_mapping()
	if multiplayer.multiplayer_peer != null:
		log_line("leave")
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	is_hosting = false
	solo = false
	room_code = ""
	route = ""
	host_note = ""


func log_line(msg: String) -> void:
	var line := "[%d] %s" % [Time.get_ticks_msec(), msg]
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


func _finish_host(ip: String, new_route: String, note: String) -> void:
	room_code = RoomCode.encode(ip, int(cfg.get("port", 0)))
	route = new_route
	host_note = note
	log_line("hosting route=%s port=%d code=%s" % [route, int(cfg.get("port", 0)), room_code])
	hosted.emit(room_code)


func _upnp_worker(gen: int, port: int) -> void:
	var result := UpnpHelper.open_port(port, UPNP_LEASE_S)
	_on_upnp_done.call_deferred(gen, port, result)


func _on_upnp_done(gen: int, port: int, result: Dictionary) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	if gen != _upnp_gen or not is_hosting:
		if result.ok:
			UpnpHelper.close_port(result.upnp, port)
		return
	if result.ok:
		_upnp = result.upnp
		_mapped_port = port
		_finish_host(result.ip, "upnp", tr("공인 IP가 방 코드에 포함됩니다. 친구에게만 보내세요."))
		return
	log_line("upnp failed: %s code=%d" % [result.error, result.code])
	_finish_host("127.0.0.1", "local", _upnp_error_text(result.error) + "\n" + tr("(이 PC 안에서만 접속 가능)"))


func _upnp_error_text(key: String) -> String:
	match key:
		"no_gateway":
			return tr("공유기가 UPnP에 응답하지 않습니다 (공유기에서 UPnP를 켜 보세요)")
		"cgnat":
			return tr("통신사 공용 IP(CGNAT)라 외부에서 접속할 수 없습니다")
		"private":
			return tr("공유기가 이중으로 연결되어 있어 외부에서 접속할 수 없습니다")
		"map_failed":
			return tr("공유기가 포트 열기를 거부했습니다")
	return tr("공인 IP를 확인하지 못했습니다")


func _close_mapping() -> void:
	if _upnp != null and _mapped_port > 0:
		UpnpHelper.close_port(_upnp, _mapped_port)
		log_line("upnp mapping closed port=%d" % _mapped_port)
	_upnp = null
	_mapped_port = 0


func _open_log(role: String) -> void:
	_log = FileAccess.open("user://net_log_%s.txt" % role, FileAccess.WRITE)


func _on_connected() -> void:
	log_line("connected to host")
	client_connected.emit()


func _on_connect_failed() -> void:
	leave()
	join_failed.emit(tr("호스트에 연결하지 못했습니다 (방이 닫혔거나 가득 참)"))


func _on_join_timeout(peer: ENetMultiplayerPeer) -> void:
	if multiplayer.multiplayer_peer == peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		leave()
		join_failed.emit(tr("연결 시간이 초과되었습니다"))


func _on_server_gone() -> void:
	log_line("host disconnected")
	connection_lost.emit(tr("호스트와의 연결이 끊겼습니다"))


func _on_peer_gone(id: int) -> void:
	if is_hosting:
		log_line("peer %d disconnected" % id)
		connection_lost.emit(tr("상대 플레이어의 연결이 끊겼습니다"))
