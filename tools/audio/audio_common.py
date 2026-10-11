"""Shared helpers for the audio tools. Needs numpy, soundfile and scipy: run them with the
generator environment, e.g.  D:\\tools\\sao\\Scripts\\python tools\\audio\\rank.py
"""
import json
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

ROOT = Path(__file__).resolve().parents[2]
AUDIO = ROOT / "assets" / "audio"
RAW = AUDIO / "_raw"  # every generated take: _raw/<key>/<key>_s<seed>.wav (+ manifest.jsonl)
SHORTLIST = AUDIO / "_shortlist"  # the best takes by score, ready to audition
PICK = AUDIO / "_pick"  # takes you chose: copy files from the shortlist into _pick/<key>/
VOICE_RAW = AUDIO / "_voice_raw"  # your recordings
CATALOG = Path(__file__).with_name("catalog.json")


def load_catalog() -> dict:
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def sound_cfg(cat: dict, key: str) -> dict:
    """Defaults, then the sound's own settings, plus the selection rules of its kind under 'want'."""
    cfg = dict(cat["defaults"])
    cfg.update(cat["sounds"][key])
    cfg["want"] = cat["kinds"][cfg["kind"]]
    return cfg


# ---- files --------------------------------------------------------------------

def read_mono(path) -> tuple[np.ndarray, int]:
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    return x.mean(axis=1), sr


def write_wav(path, x: np.ndarray, sr: int) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), np.clip(x, -1.0, 1.0), sr, subtype="PCM_16")


# ---- analysis -----------------------------------------------------------------

def envelope(x: np.ndarray, sr: int, win_ms: float = 10.0) -> np.ndarray:
    n = max(int(sr * win_ms / 1000.0), 1)
    return np.sqrt(np.convolve(x.astype(np.float64) ** 2, np.ones(n) / n, mode="same"))


def onset_index(x: np.ndarray, frac: float = 0.05) -> int:
    """First sample that reaches `frac` of the peak."""
    pk = float(np.abs(x).max()) if len(x) else 0.0
    return int(np.argmax(np.abs(x) > frac * pk)) if pk > 0.0 else 0


def count_events(x: np.ndarray, sr: int, min_gap_s: float = 0.12, rel: float = 0.3) -> int:
    """Distinct bangs / clicks: peaks of the 10 ms envelope that stand out and are far enough apart."""
    e = envelope(x, sr)
    mx = float(e.max()) if len(e) else 0.0
    if mx <= 0.0:
        return 0
    peaks, _ = signal.find_peaks(e, height=rel * mx, distance=max(int(min_gap_s * sr), 1), prominence=0.5 * rel * mx)
    return max(len(peaks), 1)


def _ramp_down(v: float, good: float, bad: float) -> float:
    """1 at or below `good`, 0 at or above `bad`."""
    return float(np.clip((bad - v) / max(bad - good, 1e-9), 0.0, 1.0))


def analyze(x: np.ndarray, sr: int, want: dict) -> dict:
    """Metrics of one take and a 0..1 score against the rules of its kind."""
    pk = float(np.abs(x).max()) if len(x) else 0.0
    if pk < 0.02:
        return {"score": 0.0, "peak": pk, "why": "silent"}
    on = onset_index(x)
    e2 = x.astype(np.float64) ** 2
    after = e2[on:]
    head_n = int(float(want["head_s"]) * sr)
    head_frac = float(after[:head_n].sum() / (after.sum() + 1e-12))
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1.0 / sr)
    centroid = float((spec * freqs).sum() / (spec.sum() + 1e-12))
    events = count_events(x[on:], sr, rel=float(want.get("event_rel", 0.3)))  # echoes below this share do not count
    clip = float((np.abs(x) > 0.99).mean())
    lo, hi = want["events"]
    ev_score = 1.0 if lo <= events <= hi else (0.4 if lo - 1 <= events <= hi + 1 else 0.1)
    c_lo, c_hi = want["centroid_hz"]
    off = np.log2(c_lo / centroid) if centroid < c_lo else (np.log2(centroid / c_hi) if centroid > c_hi else 0.0)
    parts = {
        "onset": _ramp_down(on / sr, float(want["onset_s"]) * 0.5, float(want["onset_s"]) * 2.0),
        "head": 1.0 - _ramp_down(head_frac, float(want["head_min"]) * 0.5, float(want["head_min"])) if want["head_min"] > 0 else 1.0,
        "events": ev_score,
        "centroid": float(max(0.0, 1.0 - off / 2.0)),
        "clip": 1.0 - min(clip / 0.01, 1.0),
    }
    weights = {"onset": 0.25, "head": 0.2, "events": 0.25, "centroid": 0.15, "clip": 0.15}
    score = sum(parts[k] * weights[k] for k in parts)
    score *= 0.4 + 0.6 * parts["onset"]  # a late start usually means a silent lead-in or the wrong sound
    return {"score": round(score, 3), "peak": round(pk, 3), "onset_s": round(on / sr, 3), "head_frac": round(head_frac, 3),
            "events": events, "centroid_hz": round(centroid), "clip_frac": round(clip, 5), "parts": {k: round(v, 2) for k, v in parts.items()}}


# ---- processing ---------------------------------------------------------------

def highpass(x: np.ndarray, sr: int, hz: float) -> np.ndarray:
    sos = signal.butter(2, hz, "highpass", fs=sr, output="sos")
    return signal.sosfilt(sos, x).astype(np.float32)


def trim_lead(x: np.ndarray, sr: int, lead_s: float = 0.005, frac: float = 0.05) -> np.ndarray:
    return x[max(onset_index(x, frac) - int(lead_s * sr), 0):]


def trim_tail(x: np.ndarray, sr: int, tail_s: float) -> np.ndarray:
    return x[: int(tail_s * sr)]


def fade_out(x: np.ndarray, sr: int, fade_s: float) -> np.ndarray:
    n = min(int(fade_s * sr), len(x))
    out = x.copy()
    if n > 0:
        out[-n:] *= np.linspace(1.0, 0.0, n, dtype=np.float32)
    return out


def normalize_peak(x: np.ndarray, peak: float) -> np.ndarray:
    m = float(np.abs(x).max()) if len(x) else 0.0
    return x if m == 0.0 else (x * (peak / m)).astype(np.float32)


def make_loop(x: np.ndarray, sr: int, crossfade_s: float) -> np.ndarray:
    """Seamless loop: the last `crossfade_s` fades into the first one (equal power)."""
    n = int(crossfade_s * sr)
    if n <= 0 or len(x) < 3 * n:
        return x
    t = np.linspace(0.0, np.pi / 2.0, n, dtype=np.float32)
    out = x[: len(x) - n].copy()
    out[:n] = x[:n] * np.sin(t) + x[len(x) - n:] * np.cos(t)
    return out


def trim_silence(x: np.ndarray, sr: int, thresh_db: float = -45.0, lead_s: float = 0.04, tail_s: float = 0.12) -> np.ndarray:
    """Cut the quiet before and after a recorded line, keeping a short lead-in and release."""
    e = envelope(x, sr)
    mx = float(e.max()) if len(e) else 0.0
    if mx <= 0.0:
        return x
    loud = np.nonzero(e > mx * 10.0 ** (thresh_db / 20.0))[0]
    if len(loud) == 0:
        return x
    return x[max(loud[0] - int(lead_s * sr), 0): min(loud[-1] + int(tail_s * sr), len(x))]


def level_voice(x: np.ndarray, rms_db: float = -18.0, peak: float = 0.95) -> np.ndarray:
    """Even out loudness between takes: match the RMS of the active part, then soft-limit the peaks."""
    e = np.abs(x)
    active = x[e > 0.1 * e.max()] if len(x) and e.max() > 0 else x
    rms = float(np.sqrt(np.mean(active.astype(np.float64) ** 2))) if len(active) else 0.0
    if rms <= 0.0:
        return x
    y = x * (10.0 ** (rms_db / 20.0) / rms)
    return (peak * np.tanh(y / peak)).astype(np.float32)
