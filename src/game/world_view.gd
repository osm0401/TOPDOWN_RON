class_name WorldView
extends Node2D
## Rendering and HUD for NetWorld: map, fog of sight, players, sound ripples, tracers, camera.
## Pure presentation: it only reads NetWorld state.

const FOG := Color(0.02, 0.02, 0.03, 1.0)
const FAR := 5000.0
const RIPPLE_S := 0.7
const TRACER_S := 0.1
const SOUND_COLORS := [Color(0.9, 0.9, 0.9), Color(1.0, 0.55, 0.1), Color(1.0, 0.9, 0.3)]
const SOUND_NAMES := ["footstep", "gunshot", "door"]
const PLAYER_COLORS := [Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.2)]
const DOOR_COLORS := [Color(0.62, 0.5, 0.32), Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.2)]

var world: NetWorld

var _ripples: Array[Dictionary] = []
var _tracers: Array[Dictionary] = []
var _npc_flash := 0.0
var _vis := PackedVector2Array()
var _vis_origin := Vector2.ZERO
var _show_sound := true
var _headless := DisplayServer.get_name() == "headless"
var _cam: Camera2D
var _hud: Label


func _ready() -> void:
	world.sound_emitted.connect(_on_sound)
	world.shot_fired.connect(_on_shot)
	_cam = Camera2D.new()
	add_child(_cam)
	_cam.make_current()
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 8)
	layer.add_child(_hud)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_show_sound = not _show_sound


func _physics_process(_delta: float) -> void:
	if _headless:
		return
	_vis_origin = world.display_pos(world.my_slot)
	_vis = world.level.visibility_polygon(_vis_origin, world.view_radius)


func _process(delta: float) -> void:
	for r in _ripples:
		r["age"] += delta
	for t in _tracers:
		t["age"] += delta
	_ripples = _ripples.filter(func(r: Dictionary) -> bool: return r["age"] < RIPPLE_S)
	_tracers = _tracers.filter(func(t: Dictionary) -> bool: return t["age"] < TRACER_S)
	_npc_flash = maxf(_npc_flash - delta, 0.0)
	_update_camera(delta)
	_update_hud()
	queue_redraw()


func _on_sound(kind: int, pos: Vector2) -> void:
	_ripples.append({"kind": kind, "pos": pos, "age": 0.0})


func _on_shot(_slot: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	_tracers.append({"from": from, "to": to, "age": 0.0})
	if hit_npc:
		_npc_flash = 0.25


func _update_camera(delta: float) -> void:
	var me := world.display_pos(world.my_slot)
	var screen := get_viewport_rect().size
	var off := Vector2.ZERO
	if world.auto_role == "":
		off = ((get_viewport().get_mouse_position() - screen * 0.5) * 0.3).limit_length(160.0)
	_cam.position = _cam.position.lerp(me + off, minf(delta * 12.0, 1.0))


func _draw() -> void:
	var lv := world.level
	draw_rect(lv.bounds, Color(0.09, 0.09, 0.1), true)
	draw_rect(lv.building, Color(0.17, 0.17, 0.18), true)
	draw_rect(lv.exit_zone, Color(0.1, 0.5, 0.2, 0.4), true)
	for r in lv.wall_rects:
		draw_rect(r, Color(0.45, 0.45, 0.48), true)
	for i in lv.door_rects.size():
		var col: Color = DOOR_COLORS[lv.door_actor[i]]
		if lv.is_door_open(i):
			draw_rect(lv.door_rects[i], col, false, 2.0)
		else:
			draw_rect(lv.door_rects[i], col, true)
	var npc_col := Color(1.0, 0.2, 0.2) if _npc_flash > 0.0 else (Color.YELLOW if world.npc == NetWorld.NPC_ALERT else Color.GRAY)
	draw_circle(lv.npc_pos, world.npc_radius, npc_col)
	_draw_fog()
	_draw_players()
	if _show_sound:
		_draw_ripples()
	for t in _tracers:
		draw_line(t["from"], t["to"], Color(1.0, 0.95, 0.5, 1.0 - t["age"] / TRACER_S), 2.0)


func _draw_fog() -> void:
	var n := _vis.size()
	if n < 3:
		return
	var colors := PackedColorArray([FOG, FOG, FOG, FOG])
	for i in n:
		var v := _vis[i]
		var w := _vis[(i + 1) % n]
		var fv := _vis_origin + (v - _vis_origin).normalized() * FAR
		var fw := _vis_origin + (w - _vis_origin).normalized() * FAR
		draw_primitive(PackedVector2Array([v, w, fw, fv]), colors, PackedVector2Array())


func _draw_players() -> void:
	for s in 2:
		var p := world.display_pos(s)
		draw_circle(p, NetWorld.PLAYER_RADIUS, PLAYER_COLORS[s])
		draw_line(p, p + Vector2.from_angle(world.aim[s]) * 30.0, Color.WHITE, 3.0)
		if s == world.my_slot:
			draw_arc(p, 20.0, 0.0, TAU, 24, Color.WHITE, 1.5)


func _draw_ripples() -> void:
	for r in _ripples:
		var k: float = r["age"] / RIPPLE_S
		var max_r: float = world.sound_radius[SOUND_NAMES[r["kind"]]]
		var c: Color = SOUND_COLORS[r["kind"]]
		c.a = 1.0 - k
		draw_arc(r["pos"], lerpf(8.0, max_r, k), 0.0, TAU, 48, c, 2.0)


func _update_hud() -> void:
	if world.is_host and not world.running:
		if Session.room_code == "":
			_hud.text = Session.host_note
		else:
			_hud.text = tr("방 코드: %s\n상대 플레이어 대기 중...") % Session.room_code + "\n" + Session.host_note
		return
	var w := world.weapons[world.my_slot]
	var spare := ", ".join(w.spares.map(func(n: int) -> String: return str(n)))
	var rtt := tr("호스트") if world.is_host else "%d ms" % world.rtt_ms
	_hud.text = tr("WASD 이동 / 마우스 조준 / 클릭 발사 / R 재장전 / E 문 / F 점수(샘플) / F3 소리표시 / Esc 나가기") + "\n" \
		+ tr("권총 %d  예비 탄창 %d개 (%s) %s") % [w.current, w.spares.size(), spare, tr("[재장전 중]") if w.reloading else ""] + "\n" \
		+ tr("적(샘플): %s   점수(샘플): %d   RTT: %s") % [tr("경계") if world.npc == NetWorld.NPC_ALERT else tr("대기"), world.score, rtt]
