extends Node
## Autoload "Session": connection setup only (ENet host/join, disconnect, net log).
## Game state sync lives in NetWorld, so this file is the only thing to swap for Relay/Steam.

signal hosted(code: String)
signal client_connected
signal join_failed(reason: String)
signal connection_lost(reason: String)

var cfg: Dictionary = {}
var is_hosting := false
var local_only := false
var room_code := ""

var _log: FileAccess


func _ready() -> void:
	cfg = JsonData.load_dict("res://data/net.json")
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	multiplayer.peer_disconnected.connect(_on_peer_gone)


## Opens a room (1 client max). Returns the room code, or "" on failure.
func host(force_local: bool = false) -> String:
	leave()
	var port := int(cfg.get("port", 0))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 1)
	if err != OK:
		_open_log("host")
		log_line("host failed port=%d: %s" % [port, error_string(err)])
		return ""
	multiplayer.multiplayer_peer = peer
	is_hosting = true
	var ip := "" if force_local else RoomCode.pick_vlan_ip(IP.get_local_addresses())
	local_only = ip == ""
	if local_only:
		ip = "127.0.0.1"
	room_code = RoomCode.encode(ip, port)
	_open_log("host")
	log_line("hosting %s:%d code=%s local_only=%s" % [ip, port, room_code, local_only])
	hosted.emit(room_code)
	return room_code


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
	if multiplayer.multiplayer_peer != null:
		log_line("leave")
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	is_hosting = false
	local_only = false
	room_code = ""


func log_line(msg: String) -> void:
	var line := "[%d] %s" % [Time.get_ticks_msec(), msg]
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


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
