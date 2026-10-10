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
	for i in src.size():
		if o + i >= dst.size():
			break
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
	for d_ms in [29.7, 37.1, 41.1, 43.7]:
		var d := int(float(d_ms) * 0.001 * RATE)
		var g := pow(0.001, float(d_ms) * 0.001 / decay_s)
		var y := PackedFloat32Array()
		y.resize(n)
		for i in n:
			y[i] = b[i] + (g * y[i - d] if i >= d else 0.0)
			acc[i] += y[i] * 0.25
	for ap_ms in [5.0, 1.7]:
		var d := int(float(ap_ms) * 0.001 * RATE)
		var o := PackedFloat32Array()
		o.resize(n)
		for i in n:
			o[i] = -0.7 * acc[i] + (acc[i - d] + 0.7 * o[i - d] if i >= d else 0.0)
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
