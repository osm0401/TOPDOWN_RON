class_name AimCursor
extends Control
## Mouse sensitivity during a mission. At sensitivity 1 the system cursor aims as before.
## Otherwise the cursor is captured and a drawn crosshair moves by the mouse motion times
## the sensitivity (data in GameSettings "controls/sensitivity"). Briefing, result screen
## and the pause menu always get the normal cursor back (they have buttons).
## Everything that aims reads AimCursor.screen_pos() instead of the viewport's mouse position.

static var active := false  ## the crosshair is aiming (the system cursor is captured)
static var screen := Vector2.ZERO  ## crosshair position in the viewport (px)

var world: NetWorld


static func screen_pos(vp: Viewport) -> Vector2:
	return screen if active else vp.get_mouse_position()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _exit_tree() -> void:
	_release()


func _input(event: InputEvent) -> void:
	if active and event is InputEventMouseMotion:
		var sens := float(GameSettings.value("controls", "sensitivity"))
		screen = GameSettings.aim_moved(screen, (event as InputEventMouseMotion).relative, sens, get_viewport().get_visible_rect())


func _wanted() -> bool:
	if DisplayServer.get_name() == "headless" or world == null or world.auto_role != "":
		return false
	if not world.running or world.input_blocked or world.mission.phase != MissionState.Phase.ACTIVE:
		return false
	if not DisplayServer.window_is_focused():
		return false
	return absf(float(GameSettings.value("controls", "sensitivity")) - 1.0) > 0.01


func _process(_delta: float) -> void:
	var want := _wanted()
	if want and not active:
		screen = get_viewport().get_mouse_position()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		active = true
	elif not want and active:
		_release()
	queue_redraw()


func _release() -> void:
	if not active:
		return
	active = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_inside_tree():
		Input.warp_mouse(screen)  # the system cursor comes back where the crosshair was


func _draw() -> void:
	if not active:
		return
	var c := Color(1, 1, 1, 0.85)
	var sh := Color(0, 0, 0, 0.6)
	for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(screen + d * 4.0 + Vector2.ONE, screen + d * 11.0 + Vector2.ONE, sh, 2.0)
		draw_line(screen + d * 4.0, screen + d * 11.0, c, 2.0)
	draw_circle(screen, 1.5, c)
