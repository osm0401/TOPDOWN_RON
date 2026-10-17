class_name WorldView
extends Node2D
## Rendering and HUD for NetWorld: map, fog of sight, lighting, flashlight beams, lasers,
## NPC poses and telegraphs, sound ripples, tracers, speech, progress bars, camera.
## Pure presentation: it only reads NetWorld state. Geometry queries are done in
## _physics_process and cached for drawing.

const FOG := Color(0.02, 0.02, 0.03, 1.0)
const FAR := 5000.0
const RIPPLE_S := 0.7
const TRACER_S := 0.1
const SPEECH_S := 2.4
const NOTICE_S := 3.0
const SOUND_COLORS: Array[Color] = [
	Color(0.9, 0.9, 0.9), Color(1.0, 0.55, 0.1), Color(1.0, 0.9, 0.3), Color(1.0, 0.3, 0.2),
	Color(0.5, 0.8, 1.0), Color(1.0, 0.5, 0.9), Color(0.4, 0.6, 1.0), Color(0.7, 0.7, 0.5), Color(1.0, 0.25, 0.25)]
const PLAYER_COLORS: Array[Color] = [Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.2)]
const DOOR_COLORS: Array[Color] = [Color(0.62, 0.5, 0.32), Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.2)]
const ENEMY_COLOR := Color(0.8, 0.15, 0.15)
const CIVILIAN_COLOR := Color(0.2, 0.75, 0.8)
const WEAPON_NAMES := {"pistol": "권총", "rifle_lethal": "살상 소총", "rifle_nonlethal": "비살상 소총"}
const TOOL_NAMES := {"camera": "문틈 카메라", "lockpick": "락픽", "taser": "테이저"}
const ACTION_LABELS: Array[String] = ["", "락픽", "구속", "카메라"]

## The game starts in the angled WorldView3D (data/view3d.json "start_3d"); F5 switches to this
## 2D drawing and back. Command line: --view2d / --view3d.
static var use_3d := _start_3d()

var world: NetWorld

var _view3d: WorldView3D
var _ripples: Array[Dictionary] = []
var _tracers: Array[Dictionary] = []
var _bubbles: Array[Dictionary] = []
var _flash_t := 0.0
var _was_dark := false  ## the local officer was in a dark room last frame (entry notice)
var _stun_notice_cd := 0.0  ## seconds until the "non-lethal only stuns" hint may show again
var _notice_t := 0.0
var _npc_flash: Dictionary = {}
var _vis := PackedVector2Array()
var _vis_origin := Vector2.ZERO
var _view_radius := 700.0
var _npc_seen: Array[int] = []
var _cones: Array[PackedVector2Array] = [PackedVector2Array(), PackedVector2Array()]
var _laser_dots: Array[Vector2] = [Vector2.INF, Vector2.INF]
var _show_sound := true
var _debug := true
var _headless := DisplayServer.get_name() == "headless"
var _cam: Camera2D
var _hud: Label
var _notice: Label
var _red: ColorRect


static func _start_3d() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.has("--view2d"):
		return false
	if args.has("--view3d"):
		return true
	return bool(JsonData.load_dict("res://data/view3d.json").get("start_3d", true))


func _ready() -> void:
	world.sound_emitted.connect(_on_sound)
	world.shot_fired.connect(_on_shot)
	world.speech_emitted.connect(_on_speech)
	world.notice_emitted.connect(_on_notice)
	world.damaged.connect(_on_damaged)
	_cam = Camera2D.new()
	add_child(_cam)
	_cam.make_current()
	var layer := CanvasLayer.new()
	add_child(layer)
	_red = ColorRect.new()
	_red.set_anchors_preset(Control.PRESET_FULL_RECT)
	_red.color = Color(1, 0, 0, 0)
	_red.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_red)
	_hud = Label.new()
	_hud.position = Vector2(16, 8)
	layer.add_child(_hud)
	var panel_layer := CanvasLayer.new()
	panel_layer.layer = 10
	add_child(panel_layer)
	var panel := MissionPanel.new()
	panel.world = world
	panel_layer.add_child(panel)
	_notice = Label.new()
	_notice.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_notice.position = Vector2(-300, -80)
	_notice.size = Vector2(600, 40)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_notice)
	var audio := GameAudio.new()
	audio.world = world
	add_child(audio)
	_set_3d(use_3d)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F3:
			_show_sound = not _show_sound
		elif event.physical_keycode == KEY_F4:
			_debug = not _debug
		elif event.physical_keycode == KEY_F5:
			_set_3d(not use_3d)


func _set_3d(on: bool) -> void:
	use_3d = on
	if on and _view3d == null and not _headless:
		_view3d = WorldView3D.new()
		_view3d.world = world
		_view3d.view = self
		add_child(_view3d)
	elif not on and _view3d != null:
		_view3d.queue_free()
		_view3d = null


# ---- events -------------------------------------------------------------------

func _on_sound(kind: int, pos: Vector2) -> void:
	_ripples.append({"kind": kind, "pos": pos, "age": 0.0})


func _on_shot(shooter: int, from: Vector2, to: Vector2, hit_npc: bool) -> void:
	_tracers.append({"from": from, "to": to, "age": 0.0, "npc": shooter >= 2})
	if hit_npc:
		_npc_flash[to.snapped(Vector2(8, 8))] = 0.25
		if shooter == world.my_slot and _stun_notice_cd <= 0.0:
			var ps := world.players[shooter]
			if ps.weapon_kinds.size() > ps.active and ps.weapon_kinds[ps.active] == "rifle_nonlethal":
				_on_notice(tr("비살상 소총은 기절만 시킨다: 잠시 뒤 깨어난다. 구속(E)하거나 살상 소총을 쓴다"))
				_stun_notice_cd = 20.0


func _on_speech(text: String, pos: Vector2, from_npc: bool) -> void:
	_bubbles.append({"text": text, "pos": pos, "age": 0.0, "npc": from_npc})


func _on_notice(text: String) -> void:
	_notice.text = text
	_notice_t = NOTICE_S


func _on_damaged(slot: int) -> void:
	if slot == world.my_slot:
		_flash_t = 0.35


# ---- per-frame --------------------------------------------------------------

func _view_setup() -> void:
	var me := world.players[world.my_slot]
	if me.cam_door >= 0:
		_vis_origin = world.level.door_cam_origin(me.cam_door, me.pos)
		_view_radius = float(world.tuning["actions"]["camera_view_radius"])
	else:
		_vis_origin = world.display_pos(world.my_slot)
		_view_radius = float(world.tuning["view_radius"])


func _physics_process(_delta: float) -> void:
	if _headless:
		return
	_view_setup()
	var lv := world.level
	_vis = lv.visibility_polygon(_vis_origin, _view_radius)
	var light: Dictionary = world.tuning["light"]
	for s in 2:
		var ps := world.players[s]
		var at := world.display_pos(s)
		_cones[s] = lv.cone_polygon(at, ps.aim, float(light["flash_fov_deg"]), float(light["flash_range"])) \
				if ps.flash and not ps.dead() else PackedVector2Array()
		if ps.laser and not ps.dead():
			var end := at + Vector2.from_angle(ps.aim) * float(world.tuning["laser_range"])
			var hit := lv.ray_hit(at, end)
			_laser_dots[s] = hit["position"] if not hit.is_empty() else end
		else:
			_laser_dots[s] = Vector2.INF
	_npc_seen.clear()
	for a in world.director.agents:
		_npc_seen.append(_seen_level(a.pos))


## Dark room and no flashlight: only close silhouettes show (also read by WorldView3D).
func _outline_only(ps: PlayerState, p: Vector2) -> bool:
	return not ps.dead() and not ps.flash and world.level.is_dark(p)


func _seen_level(p: Vector2) -> int:
	if p.distance_to(_vis_origin) > _view_radius:
		return LightModel.Seen.NONE
	if _vis.size() >= 3 and not Geometry2D.is_point_in_polygon(p, _vis):
		return LightModel.Seen.NONE
	var dark := world.level.is_dark(p)
	var lit := dark and world.director.lit_by_flashlight(p)
	return LightModel.visibility(dark, p.distance_to(_vis_origin), lit, float(world.tuning["light"]["silhouette_radius"]))


func _process(delta: float) -> void:
	for r in _ripples:
		r["age"] += delta
	for t in _tracers:
		t["age"] += delta
	for b in _bubbles:
		b["age"] += delta
	_ripples = _ripples.filter(func(r: Dictionary) -> bool: return r["age"] < RIPPLE_S)
	_tracers = _tracers.filter(func(t: Dictionary) -> bool: return t["age"] < TRACER_S)
	_bubbles = _bubbles.filter(func(b: Dictionary) -> bool: return b["age"] < SPEECH_S)
	for k in _npc_flash.keys():
		_npc_flash[k] -= delta
		if _npc_flash[k] <= 0.0:
			_npc_flash.erase(k)
	var me := world.players[world.my_slot]
	var dark := me.present and not me.dead() and world.level.is_dark(world.display_pos(world.my_slot))
	if dark and not _was_dark:
		_on_notice(tr("어두운 방이다: 손전등(F)으로 비춰야 적을 알아볼 수 있다"))
	_was_dark = dark
	_stun_notice_cd = maxf(_stun_notice_cd - delta, 0.0)
	_flash_t = maxf(_flash_t - delta, 0.0)
	_red.color.a = _flash_t
	_notice_t = maxf(_notice_t - delta, 0.0)
	if _notice_t <= 0.0:
		_notice.text = ""
	if _headless:
		_view_setup()
	_update_camera(delta)
	_update_hud()
	queue_redraw()


func _update_camera(delta: float) -> void:
	var me := world.players[world.my_slot]
	var target := world.display_pos(world.my_slot)
	if me.cam_door >= 0:
		target = _vis_origin
	elif world.auto_role == "":
		target += ((get_viewport().get_mouse_position() - get_viewport_rect().size * 0.5) * 0.3).limit_length(160.0)
	_cam.position = _cam.position.lerp(target, minf(delta * 12.0, 1.0))


# ---- drawing ----------------------------------------------------------------

func _draw() -> void:
	if use_3d and not _headless:
		return  # WorldView3D draws the world; HUD and mission panel stay 2D layers
	var lv := world.level
	draw_rect(lv.bounds, Color(0.09, 0.09, 0.1), true)
	draw_rect(lv.building, Color(0.17, 0.17, 0.18), true)
	for pr in lv.props:  # furniture: solid pieces filled, rugs and wall pieces faint
		var r: Rect2 = pr["rect"]
		if pr["solid"]:
			draw_rect(r, Color(0.3, 0.26, 0.22), true)
			draw_rect(r, Color(0.48, 0.42, 0.34), false, 1.0)
		else:
			draw_rect(r, Color(0.32, 0.24, 0.22, 0.5), true)
	for rm in lv.rooms:
		if rm["dark"]:
			draw_rect(rm["rect"], Color(0, 0, 0, 0.7), true)
			draw_string(ThemeDB.fallback_font, (rm["rect"] as Rect2).get_center() + Vector2(-50, 8), tr("어두운 방"),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(0.75, 0.82, 1.0, 0.45))
	draw_rect(lv.exit_zone, Color(0.1, 0.5, 0.2, 0.4), true)
	for r in lv.wall_rects:
		draw_rect(r, Color(0.45, 0.45, 0.48), true)
	_draw_doors()
	for s in 2:
		_draw_cone(_cones[s])
	_draw_npcs()
	_draw_fog()
	_draw_players()
	_draw_lasers()
	if _show_sound:
		_draw_ripples()
	for t in _tracers:
		var col := Color(1.0, 0.35, 0.3) if t["npc"] else Color(1.0, 0.95, 0.5)
		col.a = 1.0 - t["age"] / TRACER_S
		draw_line(t["from"], t["to"], col, 2.0)
	_draw_bars()
	_draw_bubbles()
	var me := world.players[world.my_slot]
	if me.cam_door >= 0:
		draw_arc(_vis_origin, 14.0, 0.0, TAU, 20, Color(0.6, 1.0, 0.6), 2.0)


func _draw_doors() -> void:
	var lv := world.level
	for i in lv.door_rects.size():
		var col: Color = DOOR_COLORS[lv.door_actor[i]]
		var st := lv.get_door_state(i)
		if st == Level.DoorState.OPEN:
			draw_rect(lv.door_rects[i], col, false, 2.0)
		else:
			draw_rect(lv.door_collider_rect(i), col, true)
			if st == Level.DoorState.AJAR:
				draw_rect(lv.door_rects[i], col, false, 1.0)
			if lv.is_locked(i):
				var c := lv.door_rects[i].get_center()
				draw_rect(Rect2(c - Vector2(4, 4), Vector2(8, 8)), Color(0.9, 0.1, 0.1), true)


func _draw_cone(poly: PackedVector2Array) -> void:
	var n := poly.size()
	if n < 3:
		return
	var col := Color(1.0, 0.95, 0.6, 0.16)
	var colors := PackedColorArray([col, col, col])
	for i in range(1, n - 1):
		draw_primitive(PackedVector2Array([poly[0], poly[i], poly[i + 1]]), colors, PackedVector2Array())


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


func _draw_npcs() -> void:
	var agents := world.director.agents
	for i in agents.size():
		var seen: int = _npc_seen[i] if i < _npc_seen.size() else LightModel.Seen.IDENTIFIED
		if _headless:
			seen = LightModel.Seen.IDENTIFIED
		if seen == LightModel.Seen.NONE:
			continue
		var a: NpcDirector.Agent = agents[i]
		if a.dormant:
			continue  # reinforcements are not in the building yet
		if seen == LightModel.Seen.SILHOUETTE:
			draw_circle(a.pos, 14.0, Color(0.35, 0.35, 0.4, 0.8))
			continue
		_draw_npc(a)


func _draw_npc(a: NpcDirector.Agent) -> void:
	var b := a.brain
	var p := a.pos
	var S := NpcBrain.State
	var base := ENEMY_COLOR if b.role == NpcBrain.Role.ENEMY else CIVILIAN_COLOR
	var flashing := false
	for k in _npc_flash:
		if (k as Vector2).distance_to(p) < 24.0:
			flashing = true
	if flashing:
		base = Color(1, 1, 1)
	match b.state:
		S.DEAD:
			draw_line(p + Vector2(-10, -10), p + Vector2(10, 10), Color(0.5, 0.5, 0.5), 3.0)
			draw_line(p + Vector2(-10, 10), p + Vector2(10, -10), Color(0.5, 0.5, 0.5), 3.0)
			_draw_dropped(a)
			_draw_status(p, tr("사망"), Color(0.75, 0.75, 0.75))
			return
		S.DOWN:
			draw_rect(Rect2(p - Vector2(14, 7), Vector2(28, 14)), base.darkened(0.2), true)
		S.RESTRAINED:
			draw_circle(p, 11.0, base.darkened(0.4))
			draw_line(p + Vector2(-8, 8), p + Vector2(8, 8), Color(0.9, 0.9, 0.2), 2.0)
		S.SURRENDER:
			draw_circle(p, 11.0, base)
			draw_line(p + Vector2(-8, -8), p + Vector2(-8, -22), base.lightened(0.3), 2.0)
			draw_line(p + Vector2(8, -8), p + Vector2(8, -22), base.lightened(0.3), 2.0)
		S.HIDE:
			draw_circle(p, 9.0, base.darkened(0.2))
		_:
			draw_circle(p, 14.0, base)
	if a.clues.has("cap"):
		draw_arc(p, 12.0, PI, TAU, 10, Color(0.0, 0.0, 0.0), 8.0)
		draw_arc(p, 12.0, PI, TAU, 10, Color(1.0, 0.1, 0.1), 4.0)
	if a.clues.has("band"):
		draw_line(p + Vector2(15, -7), p + Vector2(15, 7), Color(1.0, 0.9, 0.2), 4.0)
	var gun_up := b.armed and b.state != S.DOWN and b.state != S.HIDE
	if gun_up:
		draw_line(p, p + Vector2.from_angle(b.facing) * 26.0, Color.WHITE, 3.0)
	_draw_dropped(a)
	var pulse := 1.0 + 0.25 * sin(Time.get_ticks_msec() / 80.0)
	match b.state:
		S.DOWN:
			_draw_status(p, tr("엎드림"), Color(0.6, 0.8, 1.0))  # alive: a stunned enemy gets up again
		S.SURRENDER:
			_draw_status(p, tr("항복"), Color.WHITE)
		S.RESTRAINED:
			_draw_status(p, tr("구속"), Color(0.5, 1.0, 0.5))
		S.SPOTTED:
			draw_string(ThemeDB.fallback_font, p + Vector2(-4, -22), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.YELLOW)
		S.THREAT:
			draw_arc(p, 22.0 * pulse, 0.0, TAU, 24, Color(1.0, 0.6, 0.1), 3.0)
			draw_string(ThemeDB.fallback_font, p + Vector2(-4, -26), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1.0, 0.6, 0.1))
		S.ATTACK:
			draw_arc(p, 20.0, 0.0, TAU, 24, Color(1.0, 0.2, 0.2), 3.0)
	if _debug:
		var text := NpcBrain.STATE_NAMES[b.state]
		if b.feigning:
			text += " (가장)"
		if b.reason != "":
			text += ": " + b.reason
		draw_string(ThemeDB.fallback_font, p + Vector2(-30, 30), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))


func _draw_status(p: Vector2, text: String, color: Color) -> void:
	draw_string(ThemeDB.fallback_font, p + Vector2(-16, -26), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 0, 0, 0.8))
	draw_string(ThemeDB.fallback_font, p + Vector2(-17, -27), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)


func _draw_dropped(a: NpcDirector.Agent) -> void:
	if a.brain.had_weapon and not a.brain.armed:
		draw_line(a.pos + Vector2(12, 8), a.pos + Vector2(26, 8), Color(1.0, 0.9, 0.3), 3.0)


func _draw_players() -> void:
	for s in 2:
		var ps := world.players[s]
		var p := world.display_pos(s)
		if not ps.present:
			continue
		if ps.dead():
			draw_line(p + Vector2(-10, -10), p + Vector2(10, 10), PLAYER_COLORS[s], 3.0)
			draw_line(p + Vector2(-10, 10), p + Vector2(10, -10), PLAYER_COLORS[s], 3.0)
			continue
		draw_circle(p, NetWorld.PLAYER_RADIUS, PLAYER_COLORS[s])
		draw_line(p, p + Vector2.from_angle(ps.aim) * 30.0, Color.WHITE, 3.0)
		if s == world.my_slot:
			draw_arc(p, 20.0, 0.0, TAU, 24, Color.WHITE, 1.5)
			if _outline_only(ps, p):  # dark room, no flashlight: outlines show only inside this ring
				draw_arc(p, float(world.tuning["light"]["silhouette_radius"]), 0.0, TAU, 40, Color(0.7, 0.8, 1.0, 0.4), 1.5)
		var w := 30.0
		draw_rect(Rect2(p + Vector2(-w * 0.5, -26), Vector2(w, 4)), Color(0, 0, 0, 0.6), true)
		draw_rect(Rect2(p + Vector2(-w * 0.5, -26), Vector2(w * float(ps.hp) / maxf(ps.max_hp, 1), 4)), Color(0.3, 0.9, 0.3), true)


func _draw_lasers() -> void:
	for s in 2:
		var dot := _laser_dots[s]
		if dot == Vector2.INF:
			continue
		var p := world.display_pos(s)
		draw_line(p + Vector2.from_angle(world.players[s].aim) * 18.0, dot, Color(1.0, 0.1, 0.1, 0.75), 1.5)
		draw_circle(dot, 3.0, Color(1.0, 0.2, 0.2))


func _draw_ripples() -> void:
	var radii: Dictionary = world.tuning["sound_radius"]
	for r in _ripples:
		var k: float = r["age"] / RIPPLE_S
		var max_r := float(radii[SoundProp.NAMES[r["kind"]]])
		var c: Color = SOUND_COLORS[r["kind"]]
		c.a = 1.0 - k
		draw_arc(r["pos"], lerpf(8.0, max_r, k), 0.0, TAU, 48, c, 2.0)


func _draw_bars() -> void:
	for s in 2:
		var ps := world.players[s]
		if not ps.busy():
			continue
		var p := world.display_pos(s) + Vector2(-20, -40)
		draw_rect(Rect2(p, Vector2(40, 6)), Color(0, 0, 0, 0.7), true)
		draw_rect(Rect2(p, Vector2(40.0 * clampf(ps.action_t / ps.action_dur, 0.0, 1.0), 6)), Color(0.4, 0.9, 1.0), true)
		draw_string(ThemeDB.fallback_font, p + Vector2(0, -2), ACTION_LABELS[ps.action], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


func _draw_bubbles() -> void:
	for b in _bubbles:
		if b["npc"] and not _headless and _vis.size() >= 3 and not Geometry2D.is_point_in_polygon(b["pos"], _vis):
			continue  # NPC voices only show where we can see them
		var a: float = 1.0 - clampf((b["age"] - SPEECH_S * 0.7) / (SPEECH_S * 0.3), 0.0, 1.0)
		var at: Vector2 = (b["pos"] as Vector2) + Vector2(-40, -48 - b["age"] * 6.0)
		draw_string(ThemeDB.fallback_font, at + Vector2(1, 1), b["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0, 0, 0, a))
		draw_string(ThemeDB.fallback_font, at, b["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 0.8, a))


# ---- HUD ---------------------------------------------------------------------

func _update_hud() -> void:
	_hud.visible = (world.is_host and not world.running) or world.mission.phase == MissionState.Phase.ACTIVE
	if world.is_host and not world.running:
		if Session.room_code == "":
			_hud.text = Session.host_note
		else:
			_hud.text = tr("방 코드: %s\n상대 플레이어 대기 중...") % Session.room_code + "\n" + Session.host_note
		return
	var me := world.players[world.my_slot]
	var kind := me.weapon_kinds[me.active] if me.weapon_kinds.size() > me.active else "pistol"
	var w := me.weapons[me.active]
	var spare := ", ".join(w.spares.map(func(n: int) -> String: return str(n)))
	var tools := PackedStringArray()
	for t in me.tools:
		tools.append("%s(%d)" % [TOOL_NAMES[t], me.taser_charges] if t == "taser" else TOOL_NAMES[t])
	var d := world.director
	var E := NpcBrain.Role.ENEMY
	var C := NpcBrain.Role.CIVILIAN
	var S := NpcBrain.State
	var rtt := tr("싱글") if world.solo else (tr("호스트") if world.is_host else "%d ms" % world.rtt_ms)
	var lines := PackedStringArray()
	lines.append(tr("WASD 이동 / 클릭 사격 / R 재장전 / Q 무기교체 / E 문·구속·락픽(누르기) / Shift+E 약간 열기 / X 발로 차기"))
	lines.append(tr("C 문틈 카메라 / T 테이저 / F 손전등 / L 레이저 / 1~4 명령 / F3 소리표시 / F4 디버그 / F5 2D/3D 전환 / 휠 확대 / F6 소리 끄기 / F7 소리 시험 / Esc 나가기"))
	lines.append(tr("%s  %d / 예비 탄창 %d개 (%s) %s") % [WEAPON_NAMES[kind], w.current, w.spares.size(), spare, tr("[재장전 중]") if w.reloading else ""])
	lines.append(tr("도구: %s   손전등 %s   레이저 %s") % [", ".join(tools), tr("켬") if me.flash else tr("끔"), tr("켬") if me.laser else tr("끔")])
	lines.append(tr("체력 %d/%d%s   적: 구속 %d 사망 %d   민간인: 구속 %d 사망 %d   점수 %d   RTT %s") % [
		me.hp, me.max_hp, tr(" (사망)") if me.dead() else "",
		d.count_state(E, S.RESTRAINED), d.count_state(E, S.DEAD),
		d.count_state(C, S.RESTRAINED), d.count_state(C, S.DEAD), world.current_score(), rtt])
	if not me.dead() and world.level.is_dark(world.display_pos(world.my_slot)):
		lines.append(tr("어두운 방: 손전등 빛줄기 안의 적만 알아볼 수 있다") if me.flash else tr("어두운 방: 손전등(F)을 켜지 않으면 가까이 있는 적의 윤곽만 보인다"))
	if me.cam_door >= 0:
		lines.append(tr("문틈 카메라 사용 중 (C로 종료)"))
	if world.mission.reinforce == ReinforcementClock.Phase.WARNED:
		lines.append(tr("무전 경고: 지원 병력이 접근 중이다"))
	elif world.mission.reinforce == ReinforcementClock.Phase.ARRIVED:
		lines.append(tr("증원이 도착했다: 건물 안의 적을 모두 처리해야 한다"))
	_hud.text = "\n".join(lines)
