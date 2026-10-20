class_name MusicSynth
extends RefCounted
## PLACEHOLDER tension music made in code: four loops of the same length and tempo that play
## together, faded in by how tense the moment is (GameMusic). Nothing downloaded; pure DSP,
## deterministic. A file assets/audio/music_<layer>_0.wav replaces a layer (same loop length
## is up to whoever makes it).
##   drone   low held notes and air: always under a mission
##   pulse   a muted bass ostinato: someone knows you are here
##   drums   low drums and ticking hats: a fight is on
##   strings a high trembling cluster: the worst of it

const RATE := SfxSynth.RATE
const BPM := 120.0
const BARS := 4
const LAYERS: Array[String] = ["drone", "pulse", "drums", "strings"]
const ROOT_HZ := 73.375  ## about D2; every held frequency is a multiple of 1/8 Hz so it loops cleanly


static var _tasks: Dictionary = {}  ## layer -> WorkerThreadPool task still making it
static var _made: Dictionary = {}  ## layer -> finished stream (kept for the whole process)
static var _lock := Mutex.new()


## Starts making, one worker task per layer, every layer not in `skip` (a file replaces it)
## that is neither made nor being made. Takes a few seconds: the lobby starts it.
static func prepare(skip: Array = []) -> void:
	for layer in LAYERS:
		if layer in skip or _made.has(layer) or _tasks.has(layer):
			continue
		_tasks[layer] = WorkerThreadPool.add_task(func() -> void:
			var s := make(layer)
			_lock.lock()
			_made[layer] = s
			_lock.unlock(), false, "music " + layer)


## The layers made so far (finished tasks are collected).
static func ready_layers() -> Dictionary:
	for layer in _tasks.keys():
		if WorkerThreadPool.is_task_completed(_tasks[layer]):
			WorkerThreadPool.wait_for_task_completion(_tasks[layer])
			_tasks.erase(layer)
	_lock.lock()
	var out := _made.duplicate()
	_lock.unlock()
	return out


## Waits for every running task (at quit: no worker may outlive the game).
static func wait_all() -> void:
	for layer in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(_tasks[layer])
	_tasks.clear()


static func loop_seconds() -> float:
	return 60.0 / BPM * 4.0 * BARS


static func make(layer: String) -> AudioStreamWAV:
	match layer:
		"drone":
			return drone()
		"pulse":
			return pulse()
		"drums":
			return drums()
		"strings":
			return strings()
	return null


## Folds everything after the loop length back onto its start (tails of the last notes ring
## into the first beat on repeat), then wraps it as a looping stream.
static func _fold(b: PackedFloat32Array, peak: float) -> AudioStreamWAV:
	var n := int(loop_seconds() * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = b[i]
	for i in range(n, b.size()):
		out[i - n] += b[i]
	return SfxSynth._stream(out, 1.0, peak, true)


## Low D with its octave and fifth, slowly swelling, over dark filtered air.
static func drone() -> AudioStreamWAV:
	var secs := loop_seconds()
	var xf := 0.5
	var air := SfxSynth._lowpass(SfxSynth._lowpass(SfxSynth._white(secs + xf, 301), 260.0), 260.0)
	var out := SfxSynth._buf(secs)
	var n := out.size()
	var fade := int(xf * RATE)
	for i in n:
		var t := float(i) / RATE
		var w := air[i]
		if i < fade:  # crossfade the noise's tail into its head: no click at the loop point
			var a := float(i) / fade
			w = air[i] * a + air[n + i] * (1.0 - a)
		var swell := 0.75 + 0.25 * sin(TAU * t / secs)
		var tone := sin(TAU * ROOT_HZ * 0.5 * t) * 0.6 + sin(TAU * ROOT_HZ * t) * 0.45 + sin(TAU * (ROOT_HZ + 0.125) * t) * 0.3 \
				+ sin(TAU * 110.0 * t) * 0.18
		out[i] = tone * swell + w * 6.0
	return SfxSynth._stream(out, 1.0, 0.7, true)


## Muted bass eighths (semitones above the root), the last bar turning down a step.
static func pulse() -> AudioStreamWAV:
	var bar_a := [0, 0, 12, 0, 0, 0, 10, 0]
	var bar_b := [0, 0, 12, 0, 1, 0, 10, 7]
	var bar_c := [0, 0, 12, 0, 0, 0, 10, 0]
	var bar_d := [-2, -2, 10, -2, -4, -4, 8, 1]
	var notes: Array = bar_a + bar_b + bar_c + bar_d
	var step := 60.0 / BPM * 0.5
	var out := SfxSynth._buf(loop_seconds() + 1.0)
	for k in notes.size():
		var f := ROOT_HZ * pow(2.0, float(notes[k]) / 12.0)
		var accent := 1.0 if k % 4 == 0 else 0.7
		_mix(out, _pluck(f, 0.4), step * k, accent)
	return _fold(SfxSynth._lowpass(SfxSynth._lowpass(out, 700.0), 900.0), 0.8)


static func _pluck(f: float, seconds: float) -> PackedFloat32Array:
	var b := SfxSynth._buf(seconds)
	for i in b.size():
		var t := float(i) / RATE
		var ph := TAU * f * t
		var s := sin(ph) + sin(2.0 * ph) * 0.5 + sin(3.0 * ph) * 0.33 + sin(4.0 * ph) * 0.25 + sin(5.0 * ph) * 0.2
		b[i] = s * minf(t / 0.004, 1.0) * exp(-t / 0.11)
	return b


## Low drum hits on a broken pattern, a tom fill at the end, off-beat hats.
static func drums() -> AudioStreamWAV:
	var beat := 60.0 / BPM
	var out := SfxSynth._buf(loop_seconds() + 1.0)
	for bar in BARS:
		var b0 := bar * 4.0 * beat
		for at in [0.0, 1.5, 2.0]:
			_mix(out, SfxSynth._thump(0.45, 42.0, 130.0, 0.03, 0.14), b0 + at * beat, 1.0)
		if bar % 2 == 1:
			_mix(out, SfxSynth._thump(0.45, 42.0, 130.0, 0.03, 0.14), b0 + 3.5 * beat, 0.7)
		for k in 8:  # hats on the off-beats, a little louder on beats 2 and 4
			if k % 2 == 1:
				_mix(out, _hat(1000 + bar * 8 + k), b0 + k * beat * 0.5, 0.5 if k % 4 == 3 else 0.35)
		_mix(out, _snare(2000 + bar), b0 + 3.0 * beat, 0.55)
	var last := (BARS - 1) * 4.0 * beat
	for k in 4:  # tom fill over the last beat
		_mix(out, SfxSynth._thump(0.4, 85.0 - k * 9.0, 170.0, 0.04, 0.16), last + 3.0 * beat + k * beat * 0.25, 0.6 + k * 0.1)
	return _fold(SfxSynth._reverb(out, 0.25, 0.9), 0.85)


static func _hat(seed_: int) -> PackedFloat32Array:
	var b := SfxSynth._highpass(SfxSynth._white(0.08, seed_), 6000.0)
	SfxSynth._decay(b, 0.018)
	return b


static func _snare(seed_: int) -> PackedFloat32Array:
	var b := SfxSynth._lowpass(SfxSynth._highpass(SfxSynth._white(0.3, seed_), 900.0), 5000.0)
	SfxSynth._decay(b, 0.07)
	var body := SfxSynth._thump(0.3, 160.0, 220.0, 0.02, 0.05)
	for i in b.size():
		b[i] = b[i] * 0.8 + body[i] * 0.6
	return b


## High D, E-flat and A rubbing against each other, bowed with a fast tremolo.
static func strings() -> AudioStreamWAV:
	var secs := loop_seconds()
	var out := SfxSynth._buf(secs)
	var voices := [[293.75, 0.0], [311.125, 1.3], [440.0, 2.1], [587.5, 0.7]]
	for i in out.size():
		var t := float(i) / RATE
		var s := 0.0
		for v: Array in voices:
			var ph := TAU * float(v[0]) * t + 0.004 * float(v[0]) * sin(TAU * 5.0 * t + float(v[1]))  # vibrato, periodic in the loop
			s += sin(ph) + sin(2.0 * ph) * 0.4 + sin(3.0 * ph) * 0.2
		var trem := 0.6 + 0.4 * sin(TAU * 8.0 * t)
		var swell := 0.65 + 0.35 * sin(TAU * t / (secs * 0.5))
		out[i] = s * trem * swell
	return SfxSynth._stream(SfxSynth._lowpass(out, 2600.0), 1.0, 0.6, true)


static func _mix(dst: PackedFloat32Array, src: PackedFloat32Array, at_s: float, gain: float) -> void:
	SfxSynth._mix(dst, src, at_s, gain)
