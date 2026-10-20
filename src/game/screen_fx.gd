class_name ScreenFx
extends ColorRect
## Screen feedback for the local officer: the camera shakes when you fire or are hit (and a
## little at a loud bang close by), the screen edges flash red on a hit and, while badly hurt,
## stay red and pulse with the heartbeat while the colours drain. Shake strength: the "shake"
## graphics setting (0 = off). Tuning: data/view3d.json "screen_fx".
## The views read shake_px() and add it to their camera.

const SHADER := preload("res://src/game/screen_fx.gdshader")

var world: NetWorld

var _cfg: Dictionary = {}
var _trauma := 0.0  ## 0..1; the shake is trauma squared
var _hit := 0.0
var _t := 0.0
var _mat := ShaderMaterial.new()


func _ready() -> void:
	_cfg = JsonData.load_dict("res://data/view3d.json")["screen_fx"]
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat.shader = SHADER
	material = _mat
	visible = false
	world.shot_fired.connect(_on_shot)
	world.damaged.connect(_on_damaged)
	world.sound_emitted.connect(_on_sound)


func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func trauma() -> float:
	return _trauma


func hit_level() -> float:
	return _hit


## Camera offset (screen px) this frame.
func shake_px() -> Vector2:
	var k := _trauma * _trauma * float(_cfg["shake_px"]) * float(GameSettings.value("graphics", "shake"))
	if k <= 0.0:
		return Vector2.ZERO
	var f := float(_cfg["shake_hz"])
	return Vector2(sin(_t * f * 6.1) + 0.5 * sin(_t * f * 13.7 + 1.3), sin(_t * f * 7.3 + 2.1) + 0.5 * sin(_t * f * 11.9)) * k / 1.5


func _process(delta: float) -> void:
	_t += delta
	_trauma = maxf(_trauma - delta * float(_cfg["shake_fall_per_s"]), 0.0)
	_hit = maxf(_hit - delta / float(_cfg["hit_s"]), 0.0)
	var me := world.players[world.my_slot]
	var hurt := 0.0
	if me.present and world.mission.phase == MissionState.Phase.ACTIVE:
		hurt = HurtFeedback.rim(me.hp, me.max_hp, float(_cfg["hurt_below"]))
		if hurt > 0.0:  # the rim breathes with a heartbeat that quickens as health drops
			var bpm := lerpf(70.0, 130.0, hurt)
			var beat := fposmod(_t * bpm / 60.0, 1.0)
			hurt *= 0.75 + 0.25 * exp(-beat * 8.0)
	visible = _hit > 0.0 or hurt > 0.0
	_mat.set_shader_parameter("hit", _hit)
	_mat.set_shader_parameter("hurt", hurt)


func _on_shot(shooter: int, _from: Vector2, _to: Vector2, _hit_npc: bool) -> void:
	if shooter != world.my_slot:
		return
	var ps := world.players[shooter]
	var rifle := ps.weapon_kinds.size() > ps.active and ps.weapon_kinds[ps.active].begins_with("rifle")
	add_trauma(float(_cfg["fire_rifle" if rifle else "fire_pistol"]))


func _on_damaged(slot: int) -> void:
	if slot != world.my_slot:
		return
	add_trauma(float(_cfg["hurt_shake"]))
	_hit = 1.0


## A shot or a kicked door right next to you jolts the view a little.
func _on_sound(kind: int, pos: Vector2) -> void:
	if kind != SoundProp.Kind.GUNSHOT and kind != SoundProp.Kind.KICK:
		return
	var d := pos.distance_to(world.display_pos(world.my_slot))
	if d < 30.0 or d > float(_cfg["near_bang_px"]):  # your own shots are handled by _on_shot
		return
	add_trauma(float(_cfg["near_bang"]) * (1.0 - d / float(_cfg["near_bang_px"])))
