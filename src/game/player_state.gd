class_name PlayerState
extends RefCounted
## Everything the host tracks for one police officer (also mirrored on the client for display).

const ACTION_NONE := 0
const ACTION_LOCKPICK := 1
const ACTION_RESTRAIN := 2
const ACTION_CAMERA := 3
const ACTION_NAMES: Array[String] = ["", "lockpick", "restrain", "camera"]

var pos := Vector2.ZERO
var aim := 0.0
var hp := 5
var max_hp := 5
var flash := false
var laser := false
var active := 0                       ## 0 primary, 1 secondary (pistol)
var weapons: Array[WeaponState] = []
var weapon_kinds: Array[String] = []  ## e.g. "rifle_lethal", "pistol"
var tools: Array[String] = []
var taser_charges := 0
var action := ACTION_NONE
var action_t := 0.0
var action_dur := 1.0
var action_target := -1               ## door index or npc index
var cam_door := -1
var kick_cd := 0.0


func dead() -> bool:
	return hp <= 0


func busy() -> bool:
	return action != ACTION_NONE


func has_tool(t: String) -> bool:
	return tools.has(t)


func begin_action(kind: int, target: int, duration: float) -> void:
	action = kind
	action_target = target
	action_t = 0.0
	action_dur = maxf(duration, 0.01)
	cam_door = target if kind == ACTION_CAMERA else -1


func end_action() -> void:
	action = ACTION_NONE
	action_t = 0.0
	action_target = -1
	cam_door = -1


## [hp, flags(1 flash, 2 laser), active weapon, action, progress*1000, cam_door+1, taser charges]
func pack() -> PackedInt32Array:
	var flags := (1 if flash else 0) | (2 if laser else 0)
	var progress := int(clampf(action_t / action_dur, 0.0, 1.0) * 1000.0)
	return PackedInt32Array([hp, flags, active, action, progress, cam_door + 1, taser_charges])


func unpack(a: PackedInt32Array) -> void:
	if a.size() < 7:
		return
	hp = a[0]
	flash = (a[1] & 1) != 0
	laser = (a[1] & 2) != 0
	active = a[2]
	action = a[3]
	action_dur = 1.0
	action_t = a[4] / 1000.0
	cam_door = a[5] - 1
	taser_charges = a[6]
