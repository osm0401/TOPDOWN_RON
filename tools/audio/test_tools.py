"""Self-check of the audio tools on synthetic signals (no GPU, no model, no game files touched).

  D:\\tools\\sao\\Scripts\\python tools\\audio\\test_tools.py
"""
import json
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy import signal

import audio_common as ac
import generate
import process
import voice

SR = 44100
failed = 0


def check(cond: bool, label: str) -> None:
    global failed
    print(("PASS " if cond else "FAIL ") + label)
    failed += 0 if cond else 1


def lowpassed_noise(seconds: float, seed: int, hz: float = 2500.0) -> np.ndarray:
    x = np.random.default_rng(seed).uniform(-1, 1, int(seconds * SR)).astype(np.float32)
    return signal.sosfilt(signal.butter(2, hz, "lowpass", fs=SR, output="sos"), x).astype(np.float32)


def bang(at_s: float, total_s: float = 3.0, tau: float = 0.03, seed: int = 1) -> np.ndarray:
    """A noise burst that starts at `at_s` and decays fast, like a shot."""
    x = np.zeros(int(total_s * SR), dtype=np.float32)
    i = int(at_s * SR)
    n = min(int(0.5 * SR), len(x) - i)
    t = np.arange(n) / SR
    x[i:i + n] = lowpassed_noise(0.5, seed)[:n] * np.exp(-t / tau).astype(np.float32)
    return x / max(float(np.abs(x).max()), 1e-9) * 0.8


cat = ac.load_catalog()
rifle = ac.sound_cfg(cat, "rifle")

# ranking prefers one clean bang at the start
single = bang(0.02)
double = bang(0.02) + bang(0.6, seed=2)
late = bang(1.2)
s = {n: ac.analyze(x, SR, rifle["want"]) for n, x in {"single": single, "double": double, "late": late, "silent": np.zeros(SR)}.items()}
check(s["single"]["score"] > s["double"]["score"], "one bang scores above two bangs")
check(s["single"]["score"] > s["late"]["score"], "a bang at the start scores above a late one")
check(s["silent"]["score"] == 0.0, "silence scores zero")
check(s["single"]["events"] == 1 and s["double"]["events"] == 2, "bangs are counted")

# processing: starts at the sound, shortened, fade, normalized, no rumble
raw = np.concatenate([np.zeros(int(0.3 * SR), dtype=np.float32), bang(0.0, 4.0)]) + 0.2  # lead-in silence + DC offset
out = process.process_one(raw, SR, rifle)
check(ac.onset_index(out) < 0.02 * SR, "the processed sound starts at the bang (silence trimmed)")
check(len(out) <= int(rifle["tail_s"] * SR), "the tail is cut to the catalog length")
check(abs(float(np.abs(out).max()) - rifle["peak"]) < 0.01, "peak is normalized")
check(abs(float(out[-1])) < 0.01 and abs(float(out.mean())) < 0.02, "faded out, rumble and DC removed")

# room tone: no tail setting, keeps its length minus the crossfade
hum_cfg = ac.sound_cfg(cat, "hum")
hum_out = process.process_one(lowpassed_noise(24.0, 5, 200.0), SR, hum_cfg)
check(abs(len(hum_out) / SR - (24.0 - hum_cfg["crossfade_s"])) < 0.01, "room tone is looped over its whole length (no tail cut)")

# a far version is duller, has a longer tail and no sharp attack
near = bang(0.02, 3.0, tau=0.02)
far = ac.far_version(near, SR)


def centroid(x: np.ndarray) -> float:
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    return float((spec * np.fft.rfftfreq(len(x), 1.0 / SR)).sum() / spec.sum())


def tail_share(x: np.ndarray) -> float:
    """Share of the energy that arrives more than 0.3 s after the bang."""
    e = x.astype(np.float64) ** 2
    i = int((ac.onset_index(x) / SR + 0.3) * SR)
    return float(e[i:].sum() / e.sum())


check(centroid(far) < 0.7 * centroid(near), "the far version is much duller")
check(tail_share(far) > 3 * tail_share(near), "the far version has a longer echo tail")
check(float(np.abs(np.diff(far[: int(0.05 * SR)])).max()) < float(np.abs(np.diff(near[: int(0.05 * SR)])).max()), "the far version has a softer attack")

# looped room tone has no jump at the seam
tone = lowpassed_noise(8.0, 3, 200.0)
loop = ac.make_loop(tone, SR, 1.5)
check(len(loop) == len(tone) - int(1.5 * SR), "the loop is shorter by the crossfade")
check(abs(float(loop[0]) - float(loop[-1])) <= 4.0 * float(np.diff(tone).std()), "the loop seam is continuous")

# recorded voice: silence trimmed, loudness evened out
tone_line = (np.sin(2 * np.pi * 400 * np.arange(int(0.4 * SR)) / SR) * 0.5).astype(np.float32)
padded = np.concatenate([np.zeros(int(0.5 * SR), dtype=np.float32), tone_line, np.zeros(int(0.5 * SR), dtype=np.float32)])
trimmed = ac.trim_silence(padded, SR)
check(abs(len(trimmed) / SR - (0.4 + 0.04 + 0.12)) < 0.03, "silence around a recorded line is trimmed")
quiet, loud = ac.level_voice(tone_line * 0.1), ac.level_voice(tone_line * 1.6)
rq, rl = float(np.sqrt((quiet ** 2).mean())), float(np.sqrt((loud ** 2).mean()))
check(0.9 < rq / rl < 1.1, "quiet and loud takes end up at the same loudness")

# recording sheet and file names
lines = voice.command_lines()
keys = list(lines)
check(voice.valid_name("voice_down_2_1", keys) and voice.valid_name("voice_npc_scream_0", keys) and voice.valid_name("hurt_3", keys), "valid recording names are accepted")
check(not voice.valid_name("voice_down_2", keys) and not voice.valid_name("voice_fly_0_0", keys), "wrong recording names are refused")
sheet = voice.sheet_text(lines)
check(all(text in sheet for options in lines.values() for text in options), "the sheet lists every command sentence")
check(f"voice_{keys[-1]}_{len(lines[keys[-1]]) - 1}_0.wav" in sheet, "the sheet uses the file names the game looks for")
with tempfile.TemporaryDirectory() as tmp:
    src, dst = Path(tmp) / "raw", Path(tmp) / "out"
    src.mkdir()
    ac.write_wav(src / "voice_down_0_0.wav", padded, SR)
    ac.write_wav(src / "random.wav", padded, SR)
    done = voice.process_voices(src, dst)
    check(done == ["voice_down_0_0.wav"] and (dst / "voice_down_0_0.wav").exists() and not (dst / "random.wav").exists(), "only correctly named recordings are processed")

# generation plan resumes and estimates
with tempfile.TemporaryDirectory() as tmp:
    generate.RAW = Path(tmp)
    (Path(tmp) / "rifle").mkdir()
    for seed in (1, 2):
        (Path(tmp) / "rifle" / f"rifle_s{seed}.wav").write_bytes(b"")
    work = {w["key"]: w for w in generate.plan(cat, ["rifle"], 4, False, 1)}
    check(work["rifle"]["seeds"] == [3, 4], "existing seeds are skipped when resuming")
    check(generate.plan(cat, ["rifle"], 0, True, 1) == [], "a probe whose takes exist needs no work")
    everything = generate.plan(cat, [], 0, False, 1)
    minutes = generate.estimate_minutes(everything)
    check(len(everything) == len(cat["sounds"]) and 30 < minutes < 120, f"the whole catalog is planned (~{minutes:.0f} min)")

# process_key keeps a manifest and refuses to overwrite without --replace
with tempfile.TemporaryDirectory() as tmp:
    process.AUDIO, process.MANIFEST = Path(tmp), Path(tmp) / "manifest.json"
    take = Path(tmp) / "take.wav"
    ac.write_wav(take, bang(0.1), SR)
    outs = process.process_key("rifle", rifle, [take, take], replace=False)
    manifest = json.loads(process.MANIFEST.read_text(encoding="utf-8"))
    check([p.name for p in outs] == ["rifle_0.wav", "rifle_1.wav"] and len(manifest["rifle"]) == 2, "game files are numbered and listed in the manifest")
    try:
        process.process_key("rifle", rifle, [take], replace=False)
        check(False, "an existing sound is not overwritten without --replace")
    except SystemExit:
        check(True, "an existing sound is not overwritten without --replace")
    check(len(process.process_key("rifle", rifle, [take], replace=True)) == 1 and not (Path(tmp) / "rifle_1.wav").exists(), "--replace clears the old numbered files")

print("---- " + (f"FAILED: {failed}" if failed else "ALL PASSED"))
sys.exit(1 if failed else 0)
