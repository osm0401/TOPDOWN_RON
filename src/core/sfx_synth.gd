class_name SfxSynth
extends RefCounted
## PLACEHOLDER procedural sound effects: no audio files, nothing downloaded. Mono 16-bit PCM.
## Pure DSP, deterministic for a given seed. Swap for recorded audio later by replacing the
## streams GameAudio loads; callers only see AudioStreamWAV.

const RATE := 22050


# ---- DSP helpers --------------------------------------------------------------

static func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * RATE))
	return b


static func _white(seconds: float, seed_: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var b := _buf(seconds)
	for i in b.size():
		b[i] = rng.randf() * 2.0 - 1.0
	return b


static func _lowpass(b: PackedFloat32Array, fc: float) -> PackedFloat32Array:
	var a := 1.0 - exp(-TAU * fc / float(RATE))
	var o := PackedFloat32Array()
	o.resize(b.size())
	var y := 0.0
	for i in b.size():
		y += a * (b[i] - y)
		o[i] = y
	return o


static func _highpass(b: PackedFloat32Array, fc: float) -> PackedFloat32Array:
	var lp := _lowpass(b, fc)
	var o := PackedFloat32Array()
	o.resize(b.size())
	for i in b.size():
		o[i] = b[i] - lp[i]
	return o


## Two-pole resonator (a vocal-tract formant or a metallic ring).
static func _resonate(b: PackedFloat32Array, f: float, bw: float) -> PackedFloat32Array:
	var r := exp(-PI * bw / float(RATE))
	var c1 := 2.0 * r * cos(TAU * f / float(RATE))
	var c2 := -r * r
	var o := PackedFloat32Array()
	o.resize(b.size())
	var y1 := 0.0
	var y2 := 0.0
	for i in b.size():
		var y := (1.0 - r) * b[i] + c1 * y1 + c2 * y2
		y2 = y1
		y1 = y
		o[i] = y
	return o


## Exponential fade, in place.
static func _decay(b: PackedFloat32Array, tau: float) -> void:
	var k := exp(-1.0 / (float(RATE) * tau))
	var g := 1.0
	for i in b.size():
		b[i] *= g
		g *= k


## Adds src into dst starting at at_s seconds.
static func _mix(dst: PackedFloat32Array, src: PackedFloat32Array, at_s: float, gain := 1.0) -> void:
	var o := int(at_s * RATE)
	for i in mini(src.size(), dst.size() - o):
		dst[o + i] += src[i] * gain


## Sine sweep from f_hi down to f_lo, decaying: the body of a hit, kick or shot.
static func _thump(seconds: float, f_lo: float, f_hi: float, sweep_tau: float, tau: float) -> PackedFloat32Array:
	var o := _buf(seconds)
	var phase := 0.0
	for i in o.size():
		var t := float(i) / RATE
		phase += TAU * (f_lo + (f_hi - f_lo) * exp(-t / sweep_tau)) / RATE
		o[i] = sin(phase) * exp(-t / tau)
	return o


## Schroeder reverb (4 combs + 2 allpasses): a denser, more natural tail than filtered noise.
## `decay_s` is the time the tail takes to fall by 60 dB.
static func _reverb(b: PackedFloat32Array, wet: float, decay_s: float) -> PackedFloat32Array:
	var n := b.size()
	var acc := PackedFloat32Array()
	acc.resize(n)
	for d_ms in [29.7, 37.1, 41.1, 43.7]:  # the first d samples have no echo yet: no branch per sample
		var d := mini(int(float(d_ms) * 0.001 * RATE), n)
		var g := pow(0.001, float(d_ms) * 0.001 / decay_s)
		var y := b.duplicate()
		for i in range(d, n):
			y[i] = b[i] + g * y[i - d]
		for i in n:
			acc[i] += y[i] * 0.25
	for ap_ms in [5.0, 1.7]:
		var d := mini(int(float(ap_ms) * 0.001 * RATE), n)
		var o := PackedFloat32Array()
		o.resize(n)
		for i in d:
			o[i] = -0.7 * acc[i]
		for i in range(d, n):
			o[i] = -0.7 * acc[i] + (acc[i - d] + 0.7 * o[i - d])
		acc = o
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = b[i] + acc[i] * wet
	return out


## Soft-clips, normalizes to `peak` and wraps the samples in an AudioStreamWAV.
static func _stream(b: PackedFloat32Array, drive := 1.0, peak := 0.9, loop := false) -> AudioStreamWAV:
	var n := b.size()
	var mx := 0.0001
	for i in n:
		b[i] = tanh(b[i] * drive)
		mx = maxf(mx, absf(b[i]))
	var data := PackedByteArray()
	data.resize(n * 2)
	var g := peak / mx
	for i in n:
		data.encode_s16(i * 2, int(clampf(b[i] * g, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = n
	return s


# ---- sounds -------------------------------------------------------------------

## Layers: supersonic-style crack, muzzle body, low thump, a little noise tail, then the bang
## bouncing off nearby walls (early reflections), the action of a rifle and a dense reverb tail.
static func gunshot(seed_: int, rifle: bool) -> AudioStreamWAV:
	var len_s := 1.4 if rifle else 0.9
	var crack := _white(len_s, seed_)
	_decay(crack, 0.010 if rifle else 0.007)
	var body := _lowpass(_white(len_s, seed_ + 101), 2200.0 if rifle else 3000.0)
	_decay(body, 0.045 if rifle else 0.03)
	var tail := _lowpass(_white(len_s, seed_ + 202), 600.0)
	_decay(tail, 0.2 if rifle else 0.12)
	var thump := _thump(len_s, 50.0, 200.0 if rifle else 270.0, 0.04, 0.09)
	var out := _buf(len_s)
	for i in out.size():
		out[i] = crack[i] * 0.8 + body[i] * 1.6 + tail[i] * 0.6 + thump[i]
	var dull := _lowpass(out, 2500.0)
	for tap in [[0.011, 0.45], [0.023, 0.35], [0.038, 0.27], [0.057, 0.2], [0.083, 0.14]]:
		_mix(out, dull, tap[0], tap[1])
	if rifle:  # bolt / ejection rattle just after the shot
		var action := _resonate(_highpass(_white(0.06, seed_ + 303), 1500.0), 2400.0, 300.0)
		_decay(action, 0.012)
		_mix(out, action, 0.11, 2.0)
	return _stream(_reverb(out, 0.35, 0.7 if rifle else 0.45), 1.8, 0.95)


static func footstep(seed_: int) -> AudioStreamWAV:
	var step := _lowpass(_white(0.2, seed_), 480.0 + float(seed_ % 4) * 130.0)
	_decay(step, 0.035)
	var click := _highpass(_white(0.2, seed_ + 7), 2500.0)
	_decay(click, 0.004)
	var out := _buf(0.2)
	for i in out.size():
		out[i] = step[i] * 2.2 + click[i] * 0.35
	return _stream(out, 1.0, 0.7)


## Floors a footstep can sound like (GameAudio keys footstep_<surface>).
const STEP_SURFACES: Array[String] = ["wood", "tile", "carpet", "concrete", "grass", "asphalt"]


## Scales b so its loudest sample is `peak`, in place (layers mixed at known levels).
static func _norm(b: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var mx := 0.0001
	for v in b:
		mx = maxf(mx, absf(v))
	var g := peak / mx
	for i in b.size():
		b[i] *= g
	return b


## Noise shaped by a rise and a fall (s): a scrape, a rustle.
static func _swell(seconds: float, seed_: int, rise: float, fall: float) -> PackedFloat32Array:
	var b := _white(seconds, seed_)
	for i in b.size():
		var t := float(i) / RATE
		b[i] *= minf(t / rise, 1.0) * exp(-maxf(t - rise, 0.0) / fall)
	return b


## One boot step on `surface` (STEP_SURFACES): the heel strikes, then the sole rolls down and the
## toe touches a few hundredths later; the floor gives it its colour. Variants by seed.
static func step(seed_: int, surface: String) -> AudioStreamWAV:
	var len_s := 0.3
	var out := _buf(len_s)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_ * 7919 + surface.hash()
	var toe := rng.randf_range(0.045, 0.075)  # heel to toe
	var peak := 0.7
	match surface:
		"wood":  # hollow knock of boards on joists, a dry heel click, now and then a faint creak
			for hit: Array in [[0.0, 1.0], [toe, 0.55]]:
				var body := _resonate(_lowpass(_white(0.2, seed_ + int(hit[0] * 1000.0)), 1200.0), rng.randf_range(170.0, 240.0), 45.0)
				_decay(body, 0.045)
				var board := _resonate(_white(0.2, seed_ + 31), rng.randf_range(480.0, 620.0), 90.0)
				_decay(board, 0.02)
				var click := _highpass(_white(0.05, seed_ + 61), 2200.0)
				_decay(click, 0.003)
				_mix(out, _norm(body, 1.0), hit[0], hit[1])
				_mix(out, _norm(board, 0.5), hit[0], hit[1])
				_mix(out, _norm(click, 0.35), hit[0], hit[1])
			if rng.randf() < 0.35:
				var creak := _buf(0.12)
				var ph := 0.0
				for i in creak.size():
					var t := float(i) / RATE
					ph = fposmod(ph + (300.0 + 60.0 * sin(TAU * 9.0 * t)) / RATE, 1.0)
					creak[i] = (ph * 2.0 - 1.0) * sin(PI * t / 0.12)
				_mix(out, _norm(_lowpass(creak, 900.0), 0.18), toe + 0.02)
			peak = 0.75
		"tile":  # hard sharp heel click with a short glassy ring, the toe a lighter tap
			for hit: Array in [[0.0, 1.0], [toe, 0.5]]:
				var click := _highpass(_white(0.08, seed_ + int(hit[0] * 1000.0)), 3000.0)
				_decay(click, 0.0035)
				var ring := _resonate(_white(0.1, seed_ + 17), rng.randf_range(2300.0, 3100.0), 220.0)
				_decay(ring, 0.012)
				var thud := _lowpass(_white(0.1, seed_ + 23), 500.0)
				_decay(thud, 0.02)
				_mix(out, _norm(click, 1.0), hit[0], hit[1])
				_mix(out, _norm(ring, 0.35), hit[0], hit[1])
				_mix(out, _norm(thud, 0.7), hit[0], hit[1])
			peak = 0.8
		"carpet":  # a soft, muffled thud and the pile brushing the sole: no click
			var thud := _lowpass(_lowpass(_white(0.2, seed_), 300.0), 300.0)
			_decay(thud, 0.05)
			var brush := _lowpass(_lowpass(_highpass(_swell(0.2, seed_ + 5, 0.02, 0.05), 900.0), 2500.0), 2500.0)
			_mix(out, _norm(thud, 1.0), 0.0)
			_mix(out, _norm(brush, 0.15), toe * 0.5)
			_mix(out, _norm(_lowpass(_lowpass(_white(0.15, seed_ + 9), 260.0), 260.0), 0.4), toe)
			peak = 0.4
		"concrete", "asphalt":  # firm thump, a click, then grit crunching under the sole
			for hit: Array in [[0.0, 1.0], [toe, 0.6]]:
				var thud := _lowpass(_white(0.12, seed_ + int(hit[0] * 1000.0)), 650.0)
				_decay(thud, 0.025)
				var click := _highpass(_white(0.05, seed_ + 41), 1800.0)
				_decay(click, 0.004)
				_mix(out, _norm(thud, 1.0), hit[0], hit[1])
				_mix(out, _norm(click, 0.55 if surface == "concrete" else 0.35), hit[0], hit[1])
			var grit := _highpass(_swell(0.2, seed_ + 77, 0.01, 0.05 if surface == "concrete" else 0.08), 2500.0)
			for i in grit.size():  # crackle: sparse little grains rather than a smooth hiss
				grit[i] *= 1.0 if rng.randf() < 0.25 else 0.15
			_mix(out, _norm(grit, 0.3 if surface == "concrete" else 0.5), 0.01)
			peak = 0.7 if surface == "concrete" else 0.65
		"grass":  # blades rustling and a soft thud of the earth under them
			var rustle := _lowpass(_lowpass(_highpass(_swell(0.28, seed_, 0.03, 0.07), 1200.0), 4500.0), 4500.0)
			for i in rustle.size():
				rustle[i] *= 0.6 + 0.4 * sin(TAU * rng.randf_range(20.0, 40.0) * float(i) / RATE)
			var thud := _lowpass(_lowpass(_white(0.15, seed_ + 3), 220.0), 220.0)
			_decay(thud, 0.04)
			_mix(out, _norm(rustle, 0.8), 0.0)
			_mix(out, _norm(thud, 0.6), 0.005)
			peak = 0.45
	return _stream(out, 1.0, peak)


## Magazine released and pulled out of the well: a latch click and a metal slide.
static func mag_out(seed_: int) -> AudioStreamWAV:
	var out := _buf(0.35)
	var latch := _resonate(_highpass(_white(0.05, seed_), 2000.0), 3400.0, 400.0)
	_decay(latch, 0.006)
	_mix(out, _norm(latch, 1.0), 0.0)
	var slide := _highpass(_lowpass(_swell(0.18, seed_ + 1, 0.04, 0.05), 5000.0), 900.0)
	_mix(out, _norm(slide, 0.45), 0.03)
	return _stream(out, 1.2, 0.6)


## A full magazine seated in the well: a slide in, then a firm clack.
static func mag_in(seed_: int) -> AudioStreamWAV:
	var out := _buf(0.4)
	var slide := _highpass(_lowpass(_swell(0.12, seed_, 0.06, 0.02), 4500.0), 900.0)
	_mix(out, _norm(slide, 0.4), 0.0)
	var clack := _highpass(_white(0.06, seed_ + 2), 1200.0)
	_decay(clack, 0.008)
	var ring := _resonate(_white(0.15, seed_ + 3), 2100.0, 160.0)
	_decay(ring, 0.03)
	_mix(out, _norm(clack, 1.0), 0.1)
	_mix(out, _norm(ring, 0.4), 0.1)
	_mix(out, _norm(_thump(0.12, 90.0, 150.0, 0.02, 0.035), 0.5), 0.1)
	return _stream(out, 1.3, 0.75)


## Bolt (or slide) pulled back and let go: a rasp and a hard snap forward.
static func bolt(seed_: int) -> AudioStreamWAV:
	var out := _buf(0.45)
	var back := _highpass(_lowpass(_swell(0.1, seed_, 0.05, 0.02), 5000.0), 1200.0)
	_mix(out, _norm(back, 0.5), 0.0)
	var snap := _highpass(_white(0.06, seed_ + 4), 1500.0)
	_decay(snap, 0.006)
	var ring := _resonate(_white(0.2, seed_ + 5), 2800.0, 120.0)
	_decay(ring, 0.04)
	_mix(out, _norm(snap, 1.0), 0.14)
	_mix(out, _norm(ring, 0.45), 0.14)
	_mix(out, _norm(_thump(0.1, 110.0, 180.0, 0.015, 0.03), 0.4), 0.14)
	return _stream(out, 1.4, 0.8)


## Creaking hinge swell with a latch click and a soft settle.
static func door(seed_: int, seconds: float, peak: float) -> AudioStreamWAV:
	var out := _buf(seconds)
	var phase := 0.0
	for i in out.size():
		var t := float(i) / RATE
		phase = fposmod(phase + (140.0 + 90.0 * sin(PI * t / seconds) + 20.0 * sin(TAU * 7.0 * t)) / RATE, 1.0)
		out[i] = (phase * 2.0 - 1.0) * sin(PI * t / seconds) * 0.5
	out = _lowpass(out, 700.0)
	var latch := _highpass(_white(0.05, seed_), 1500.0)
	_decay(latch, 0.006)
	_mix(out, latch, 0.0, 0.8)
	_mix(out, _thump(0.2, 60.0, 90.0, 0.05, 0.06), maxf(seconds - 0.18, 0.0), 0.5)
	return _stream(out, 1.5, peak)


static func kick(seed_: int) -> AudioStreamWAV:
	var out := _thump(0.8, 32.0, 110.0, 0.05, 0.12)
	var crack := _highpass(_lowpass(_white(0.8, seed_), 4000.0), 800.0)
	_decay(crack, 0.02)
	var rattle := _lowpass(_white(0.8, seed_ + 5), 1800.0)
	for i in rattle.size():
		rattle[i] *= 0.5 + 0.5 * signf(sin(TAU * 35.0 * float(i) / RATE))
	_decay(rattle, 0.18)
	for i in out.size():
		out[i] += crack[i] * 0.9
	_mix(out, rattle, 0.03, 0.5)
	return _stream(_reverb(out, 0.3, 0.5), 2.2, 0.95)


## Ear ringing after a loud bang: a few thin high tones that slowly fade.
static func ringing() -> AudioStreamWAV:
	var out := _buf(3.5)
	for i in out.size():
		var t := float(i) / RATE
		var wobble := 1.0 + 0.08 * sin(TAU * 0.7 * t)
		out[i] = (sin(TAU * 3150.0 * t) * 0.6 + sin(TAU * 5230.0 * t) * 0.3 + sin(TAU * 7010.0 * t) * 0.1) \
				* exp(-t / 1.4) * minf(t / 0.05, 1.0) * wobble
	return _stream(out, 1.0, 0.5)


static func taser(seed_: int) -> AudioStreamWAV:
	var n := _highpass(_white(0.9, seed_), 1800.0)
	for i in n.size():
		var t := float(i) / RATE
		var gate := 1.0 if fposmod(t * 32.0, 1.0) < 0.35 else 0.0
		n[i] = n[i] * gate * (1.0 if t < 0.7 else maxf(0.0, 1.0 - (t - 0.7) / 0.2)) + sin(TAU * 3800.0 * t) * 0.08
	return _stream(n, 1.5, 0.8)


## Shouted vowel: glottal pulses through three formants. f0 ~110 Hz deep voice, ~450 Hz scream.
static func shout(seed_: int, f0: float, seconds: float, harsh: float) -> AudioStreamWAV:
	var src := _buf(seconds)
	var breath := _white(seconds, seed_)
	var phase := 0.0
	for i in src.size():
		var t := float(i) / RATE
		var f := f0 * (1.0 + 0.03 * sin(TAU * 5.5 * t)) * (1.0 + 0.15 * exp(-t / 0.08))
		phase = fposmod(phase + f / RATE, 1.0)
		src[i] = pow(1.0 - phase, 3.0) * 2.0 - 0.5 + breath[i] * 0.06 * harsh
	var a := _resonate(src, 800.0, 90.0)
	var b := _resonate(src, 1200.0, 110.0)
	var c := _resonate(src, 2800.0, 170.0)
	var out := _buf(seconds)
	for i in out.size():
		var t := float(i) / RATE
		var env := minf(t / 0.03, 1.0) * clampf((seconds - t) / 0.15, 0.0, 1.0)
		out[i] = (a[i] + b[i] * 0.6 + c[i] * 0.25) * env
	return _stream(out, 1.0 + harsh, 0.85)


static func siren() -> AudioStreamWAV:
	var out := _buf(2.2)
	var phase := 0.0
	for i in out.size():
		var t := float(i) / RATE
		phase = fposmod(phase + (850.0 + 350.0 * sin(TAU * 0.45 * t)) / RATE, 1.0)
		out[i] = tanh(3.0 * sin(TAU * phase)) * minf(t / 0.1, 1.0) * clampf((2.2 - t) / 0.2, 0.0, 1.0)
	return _stream(_lowpass(out, 2500.0), 1.0, 0.6)


## Magazine out, slide rasp, magazine in.
static func reload_sound(seed_: int) -> AudioStreamWAV:
	var out := _buf(1.0)
	var click := _highpass(_white(0.08, seed_), 2000.0)
	_decay(click, 0.006)
	_mix(out, click, 0.0, 0.8)
	var rasp := _lowpass(_white(0.2, seed_ + 3), 3000.0)
	for i in rasp.size():
		rasp[i] *= sin(PI * float(i) / rasp.size())
	_mix(out, rasp, 0.40, 0.5)
	var click2 := _highpass(_white(0.08, seed_ + 9), 1500.0)
	_decay(click2, 0.008)
	_mix(out, click2, 0.72, 1.0)
	_mix(out, _thump(0.12, 90.0, 140.0, 0.02, 0.04), 0.72, 0.5)
	return _stream(out, 1.2, 0.7)


## Bullet into a body.
static func hit(seed_: int) -> AudioStreamWAV:
	var out := _thump(0.25, 55.0, 120.0, 0.05, 0.06)
	var flesh := _lowpass(_white(0.25, seed_), 900.0)
	_decay(flesh, 0.03)
	for i in out.size():
		out[i] += flesh[i] * 1.5
	return _stream(out, 1.6, 0.85)


## The local officer is hit: heavy thud, a grunt and a short noise burst.
static func hurt(seed_: int) -> AudioStreamWAV:
	var out := _thump(0.5, 45.0, 110.0, 0.06, 0.12)
	var burst := _lowpass(_white(0.5, seed_), 1200.0)
	_decay(burst, 0.05)
	for i in out.size():
		out[i] += burst[i] * 1.2
	var g := shout(seed_, 120.0, 0.3, 1.0).data
	var grunt := PackedFloat32Array()
	grunt.resize(g.size() / 2)
	for i in grunt.size():
		grunt[i] = float(g.decode_s16(i * 2)) / 32768.0
	_mix(out, grunt, 0.02, 0.5)
	return _stream(out, 1.4, 0.9)


## Radio squelch: key-up click, a burst of band-limited static and two short beeps.
static func radio(seed_: int) -> AudioStreamWAV:
	var out := _buf(0.8)
	var click := _highpass(_white(0.02, seed_), 1200.0)
	_decay(click, 0.004)
	_mix(out, click, 0.0, 1.0)
	var hiss := _highpass(_lowpass(_white(0.45, seed_ + 1), 3500.0), 900.0)
	for i in hiss.size():
		hiss[i] *= minf(float(i) / (0.03 * RATE), 1.0) * clampf((0.45 - float(i) / RATE) / 0.12, 0.0, 1.0)
	_mix(out, hiss, 0.02, 0.5)
	for beep_at in [0.32, 0.46]:
		var beep := _buf(0.08)
		for i in beep.size():
			beep[i] = sin(TAU * 1250.0 * float(i) / RATE) * sin(PI * float(i) / beep.size())
		_mix(out, beep, beep_at, 0.35)
	return _stream(_highpass(_lowpass(out, 3800.0), 500.0), 1.4, 0.7)


## One heartbeat: a soft low "lub" followed by a lighter "dub".
static func heart() -> AudioStreamWAV:
	var out := _buf(0.7)
	_mix(out, _thump(0.25, 45.0, 75.0, 0.03, 0.07), 0.0, 1.0)
	_mix(out, _thump(0.2, 50.0, 85.0, 0.03, 0.05), 0.22, 0.7)
	return _stream(out, 1.2, 0.8)


## Low room tone: mains hum plus rumble. Loops seamlessly (whole cycles + crossfaded noise).
static func hum() -> AudioStreamWAV:
	var n := 4.0
	var xf := 0.15
	var noise := _lowpass(_white(n + xf, 5), 220.0)
	var out := _buf(n)
	var count := out.size()
	var fade := int(xf * RATE)
	for i in count:
		var t := float(i) / RATE
		var w := noise[i]
		if i < fade:
			var a := float(i) / fade
			w = noise[i] * a + noise[count + i] * (1.0 - a)
		out[i] = sin(TAU * 50.0 * t) * 0.5 + sin(TAU * 100.0 * t) * 0.2 + sin(TAU * 150.0 * t) * 0.05 + w * 3.0
	return _stream(out, 1.0, 0.6, true)


## Rain round the building: a soft hiss, the low patter of many drops and single drops ticking
## close by. Loops without a seam (its end crossfades into its start).
static func rain() -> AudioStreamWAV:
	var n := 3.0
	var xf := 0.25
	var hiss := _lowpass(_highpass(_white(n + xf, 21), 500.0), 4500.0)
	var patter := _lowpass(_white(n + xf, 22), 260.0)
	var out := _buf(n)
	var count := out.size()
	var fade := int(xf * RATE)
	for i in count:
		var h := hiss[i]
		var p := patter[i]
		if i < fade:
			var a := float(i) / fade
			h = hiss[i] * a + hiss[count + i] * (1.0 - a)
			p = patter[i] * a + patter[count + i] * (1.0 - a)
		out[i] = h * 0.8 + p * 2.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var tick := _highpass(_white(0.012, 24), 2500.0)
	_decay(tick, 0.003)
	for d in 260:  # near drops, wrapped round the loop
		var at := rng.randi() % count
		var g := rng.randf_range(-0.35, 0.35)
		for i in tick.size():
			out[(at + i) % count] += tick[i] * g
	return _stream(out, 1.0, 0.5, true)


## Thunder far away: a dull crack, then a rumble that rolls in two or three swells and dies out.
static func thunder(seed_: int) -> AudioStreamWAV:
	var secs := 5.0
	var rumble := _lowpass(_lowpass(_white(secs, seed_), 160.0), 90.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_ + 1
	var rolls := [[0.0, 0.25, 1.0], [rng.randf_range(0.6, 1.4), 0.5, rng.randf_range(0.5, 0.9)],
			[rng.randf_range(1.6, 2.6), 0.8, rng.randf_range(0.4, 0.7)]]  # start s, length s, strength
	var block := 64  # the swells change slowly: their envelope once per block
	for b0 in range(0, rumble.size(), block):
		var t := float(b0) / RATE
		var env := 0.0
		for r: Array in rolls:
			var dt := t - float(r[0])
			if dt > 0.0:
				env += float(r[2]) * minf(dt / 0.15, 1.0) * exp(-dt / (float(r[1]) + 1.2))
		for i in range(b0, mini(b0 + block, rumble.size())):
			rumble[i] *= env
	var out := rumble
	var tail := int(1.5 * RATE)  # the last swell fades all the way out
	for i in tail:
		out[out.size() - tail + i] *= 1.0 - float(i) / tail
	var crack := _lowpass(_highpass(_white(0.4, seed_ + 2), 300.0), 2500.0)
	_decay(crack, 0.09)
	_mix(out, crack, 0.02, 0.06)
	return _stream(out, 1.5, 0.8)
