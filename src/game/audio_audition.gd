class_name AudioAudition
extends CanvasLayer
## F7: listen to every sound of the bank in the real game mix: pick the sound and its variant,
## how far away it is (which bus it goes through) and what kind of room it rings in.
## A sound from a file shows "file", a synthesized stand-in shows "synth".

## [label, loudness, behind a wall]
const DISTANCES: Array = [["가까움", 0.9, false], ["중간", 0.5, false], ["멀리", 0.2, false], ["벽 뒤", 0.45, true]]
## [label, longest side in meters; -1 = the room you stand in, 0 = outdoors]
const ROOMS: Array = [["현재 위치", -1.0], ["야외", 0.0], ["작은 방 5 m", 5.0], ["큰 방 12 m", 12.0], ["복도 23 m", 23.0]]

var audio: GameAudio

var _label: Label
var _key := 0
var _variant := 0
var _dist := 0
var _room := 0


func _ready() -> void:
	layer = 20
	var box := ColorRect.new()
	box.color = Color(0, 0, 0, 0.7)
	box.position = Vector2(16, 400)
	box.size = Vector2(620, 118)
	add_child(box)
	_label = Label.new()
	_label.position = Vector2(28, 408)
	add_child(_label)
	visible = false


func _exit_tree() -> void:
	if is_instance_valid(audio):
		audio.audition_reverb = {}


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var code: int = event.physical_keycode
	if code == KEY_F7:
		visible = not visible
		_apply_room()
		_refresh()
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	var keys := audio.bank_keys()
	match code:
		KEY_UP:
			_key = posmod(_key - 1, keys.size())
			_variant = 0
		KEY_DOWN:
			_key = posmod(_key + 1, keys.size())
			_variant = 0
		KEY_LEFT:
			_variant -= 1
		KEY_RIGHT:
			_variant += 1
		KEY_BRACKETLEFT:
			_dist = posmod(_dist - 1, DISTANCES.size())
		KEY_BRACKETRIGHT:
			_dist = posmod(_dist + 1, DISTANCES.size())
		KEY_MINUS:
			_room = posmod(_room - 1, ROOMS.size())
			_apply_room()
		KEY_EQUAL:
			_room = posmod(_room + 1, ROOMS.size())
			_apply_room()
		KEY_SPACE, KEY_ENTER:
			var d: Array = DISTANCES[_dist]
			audio.audition_play(keys[_key], _variant, float(d[1]), bool(d[2]))
		_:
			return
	var count := maxi(audio.variants_of(keys[_key]).size(), 1)
	_variant = posmod(_variant, count)
	_refresh()
	get_viewport().set_input_as_handled()


func _apply_room() -> void:
	var size_m: float = ROOMS[_room][1]
	if not visible or size_m < 0.0:
		audio.audition_reverb = {}
	elif size_m == 0.0:
		audio.audition_reverb = audio.reverb_outdoor()
	else:
		audio.audition_reverb = audio.reverb_for_size(size_m)


func _refresh() -> void:
	var keys := audio.bank_keys()
	var key: String = keys[_key]
	var variants := audio.variants_of(key)
	var origin := "-"
	if not variants.is_empty():
		origin = tr("파일") if (variants[_variant % variants.size()] as Resource).resource_path != "" else tr("합성")
	_label.text = "%s\n%s: %s   %s %d/%d (%s)\n%s: %s   %s: %s\n%s" % [
		tr("소리 시험 (F7로 닫기)"), tr("소리"), key, tr("변형"), _variant + 1, maxi(variants.size(), 1), origin,
		tr("거리"), DISTANCES[_dist][0], tr("울림"), ROOMS[_room][0],
		tr("↑↓ 소리   ←→ 변형   [ ] 거리   - = 울림   Space 재생")]
