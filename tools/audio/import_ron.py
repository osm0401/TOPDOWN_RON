"""Ready or Not sound import: finds the best officer voice lines and weapon sounds in the folders you
exported, turns them into game files, checks every file it wrote and swaps out the bad ones.

  python tools/audio/import_ron.py                 # folders from import_ron.json, apply to the game
  python tools/audio/import_ron.py --dry-run       # only the report: nothing in the game changes
  python tools/audio/import_ron.py --only voice    # voice | weapons
  python tools/audio/import_ron.py --no-asr        # no speech recognition: line table and file names only
  python tools/audio/import_ron.py verify [--fix]  # check every game file in assets/audio (old ones too)

Voice: speech recognition (faster-whisper, else openai-whisper) hears what every file in the voice folder
says, so the lines of the table in import_ron.json and lines of the same meaning are found by their
words; the numbered file group that fits the table and the file names back it up (and are all there is
without speech recognition). Each command sentence gets up to 4 takes voice_<command>_<line>_<take>.wav.
Weapons: file names give the gun type and the layer (close shot, far, tail, reload...), the catalog
rules score every candidate, and the takes of one gun are kept together. A missing far set is made
from the close shots (make_far.py), a missing full reload is put together from magazine and bolt sounds.
After writing, every game file is checked (empty, silent, too short or long, clipped, offset, and
for voices: still says the line after trimming); a bad one is replaced by the next best candidate.

Your own choice wins over the automatic one: assets/audio/_import/pins.json (not committed) names the
files to use, see load_pins().

Everything it decided: assets/audio/_import/REPORT.md, inventory.csv, choices.json. Files it replaced:
assets/audio/_backup/<time>/. The imported sounds belong to VOID Interactive: assets/audio is never
committed (.gitignore), keep them for your own testing.
"""
import argparse
import csv
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np
from scipy import signal

import audio_common as ac
import process
import ron_match as rm
from make_far import far_take

CONFIG = Path(__file__).with_name("import_ron.json")
COMMANDS = ac.ROOT / "data" / "commands.json"
WORK = ac.AUDIO / "_import"
BACKUP = ac.AUDIO / "_backup"
AUDIO_EXTS = [".wav", ".flac", ".ogg", ".opus", ".mp3", ".aif", ".aiff", ".wem", ".binka", ".fsb", ".bank"]  # preferred first
TAKES = 4  # voice_<command>_<line>_0..3.wav (GameAudio.MAX_TAKES)
MAX_VARIANTS = 16  # <key>_0..15.wav (GameAudio.MAX_VARIANTS)
VOICE_MIN_S = 0.25
POOR = 0.55  # radio voice, clipped: used only for a command that has nothing better
OUTLIER = 0.1  # a weapon take this far below the best take of its group is left out
RADIO_WORDS = {"radio", "rdo", "comms", "comm", "walkie", "headset", "radioed"}
HOW_RANK = {"pin": -1, "table+asr": 0, "table": 0, "asr-table": 1, "asr": 2, "name": 3, "table?": 4}
HOW_KO = {"pin": "직접 지정", "table+asr": "표 번호+음성 인식", "table": "표 번호", "asr-table": "음성 인식(표 대사)", "asr": "음성 인식",
          "name": "파일 이름", "table?": "표 번호(인식 불확실)"}


def say(msg: str) -> None:
    print(msg, flush=True)


# ---- files --------------------------------------------------------------------

def list_audio(folder: Path) -> tuple[list[Path], Counter]:
    """Sound files under `folder`; one sound exported in two formats (x.wav and x.ogg) counts once."""
    best: dict[str, Path] = {}
    exts = Counter()
    for dirpath, _, names in os.walk(folder):
        for n in names:
            stem, ext = os.path.splitext(n)
            ext = ext.lower()
            exts[ext or "(none)"] += 1
            if ext not in AUDIO_EXTS:
                continue
            key = os.path.join(dirpath, stem).lower()
            if key not in best or AUDIO_EXTS.index(ext) < AUDIO_EXTS.index(best[key].suffix.lower()):
                best[key] = Path(dirpath) / n
    return sorted(best.values()), exts


def decode(path: Path) -> tuple[np.ndarray, int]:
    """Mono float audio. soundfile first (wav, ogg, flac, mp3), then ffmpeg when it is installed."""
    try:
        x, sr = ac.read_mono(path)
        return x.astype(np.float32), sr
    except Exception as first:
        if shutil.which("ffmpeg"):
            r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "1", "-ar", "48000", "-"],
                               capture_output=True)
            if r.returncode == 0 and len(r.stdout) >= 4:
                return np.frombuffer(r.stdout, "<f4").copy(), 48000
        raise RuntimeError(f"cannot read: {first}") from None


def to16k(x: np.ndarray, sr: int) -> np.ndarray:
    if sr == 16000:
        return x.astype(np.float32)
    g = math.gcd(16000, sr)
    return signal.resample_poly(x, 16000 // g, sr // g).astype(np.float32)


def audio_hash(x: np.ndarray) -> str:
    return hashlib.md5(np.round(x * 4096.0).astype(np.int16).tobytes()).hexdigest()[:16]


def safe_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_\-]+", "_", text).strip("_")[:80] or "x"


def remove_game_file(path: Path) -> None:
    """A game file and its Godot import file (a stale .import would keep the old sound loadable)."""
    for p in (path, path.with_name(path.name + ".import")):
        if p.exists():
            p.unlink()


def drop_orphan_imports() -> int:
    n = 0
    for imp in ac.AUDIO.glob("*.wav.import"):
        if not imp.with_name(imp.name[: -len(".import")]).exists():
            imp.unlink()
            n += 1
    return n


def load_pins() -> dict:
    """assets/audio/_import/pins.json: files chosen by hand, used instead of the automatic choice.
      "voice":   {"<command>": [[file, ...] per sentence of commands.json, in take order]}
      "hurt":    [file, ...]
      "weapons": {"<key>": [file, or [[file, at_s, peak], ...] = files mixed at those times, ...]}
    An empty weapons list leaves that sound as it is. File names are relative to the voice / weapons folder."""
    path = WORK / "pins.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def mix_parts(pieces: list[tuple[Path, float, float]], max_s: float = 3.0) -> tuple[np.ndarray, int]:
    """Files laid over each other: (file, start in seconds, peak it is normalized to)."""
    sr, layers = None, []
    for path, at, peak in pieces:
        x, s = decode(path)
        if sr is None:
            sr = s
        elif s != sr:
            g = math.gcd(sr, s)
            x = signal.resample_poly(x, sr // g, s // g).astype(np.float32)
        layers.append((int(float(at) * sr), ac.normalize_peak(ac.trim_lead(x, sr), float(peak))))
    total = max(i + len(x) for i, x in layers) + int(0.1 * sr)
    mix = np.zeros(min(total, int(max_s * sr)), dtype=np.float32)
    for i, x in layers:
        n = max(min(len(x), len(mix) - i), 0)
        mix[i: i + n] += x[:n]
    return ac.normalize_peak(mix, 0.9), sr  # overlapping parts can add up past full scale


class Backup:
    """Copies every game file before it is replaced or deleted, once per run."""

    def __init__(self, dry: bool):
        self.dir = BACKUP / datetime.now().strftime("%Y%m%d-%H%M%S")
        self.dry = dry
        self.saved: list[str] = []

    def keep(self, path: Path) -> None:
        if self.dry or not path.exists():
            return
        rel = path.relative_to(ac.AUDIO).as_posix().replace("/", "__")
        dst = self.dir / rel
        if dst.exists():
            return
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dst)
        self.saved.append(rel)


# ---- speech recognition ---------------------------------------------------------

def load_asr(model: str):
    """(transcribe(x16k) -> (text, confidence, no_speech), description), or (None, why not)."""
    why = []
    try:
        from faster_whisper import WhisperModel
        for device, ctype in (("cuda", "float16"), ("cpu", "int8")):
            try:
                m = WhisperModel(model, device=device, compute_type=ctype)

                def run(x, m=m):
                    segs, _ = m.transcribe(x, language="en", beam_size=5, condition_on_previous_text=False,
                                           without_timestamps=True, vad_filter=False)
                    segs = list(segs)
                    text = " ".join(s.text.strip() for s in segs).strip()
                    conf = float(np.mean([math.exp(s.avg_logprob) for s in segs])) if segs else 0.0
                    return text, conf, float(max((s.no_speech_prob for s in segs), default=1.0))

                run(np.zeros(16000, dtype=np.float32))  # CUDA libraries fail on first use, not on load
                return run, f"faster-whisper {model} ({device})"
            except Exception as e:  # no GPU libraries: try the CPU
                why.append(f"faster-whisper {device}: {e}")
    except ImportError:
        why.append("faster-whisper not installed")
    try:
        import torch
        import whisper
        dev = "cuda" if torch.cuda.is_available() else "cpu"
        m = whisper.load_model(model, device=dev)

        def run(x, m=m):
            r = m.transcribe(x, language="en", fp16=dev == "cuda", temperature=0.0, condition_on_previous_text=False)
            segs = r.get("segments", [])
            conf = float(np.mean([math.exp(s["avg_logprob"]) for s in segs])) if segs else 0.0
            return r["text"].strip(), conf, float(max((s["no_speech_prob"] for s in segs), default=1.0))

        return run, f"openai-whisper {model} ({dev})"
    except Exception as e:
        why.append(f"openai-whisper: {e}")
    return None, "; ".join(why)


def transcribe(recs: list[dict], run, desc: str, max_s: float) -> None:
    """Fills rec['text'] / ['conf'] / ['nsp'] for every readable voice file up to max_s long.
    Results are cached in _import/transcripts.json, so a second run is fast."""
    cache_path = WORK / "transcripts.json"
    cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    todo = [r for r in recs if not r.get("error") and 0.1 < r["dur"] <= max_s and r["peak"] >= 0.003]
    t0, done = time.time(), 0
    for i, r in enumerate(todo):
        sig = f"{r['size']}:{r['mtime']}:{desc.split(' (')[0]}"
        c = cache.get(r["rel"])
        if c and c.get("sig") == sig:
            r.update(text=c["text"], conf=c["conf"], nsp=c["nsp"])
            continue
        x, sr = decode(r["path"])
        r["text"], r["conf"], r["nsp"] = run(to16k(x, sr))
        cache[r["rel"]] = {"sig": sig, "text": r["text"], "conf": round(r["conf"], 3), "nsp": round(r["nsp"], 3)}
        done += 1
        if done % 25 == 0:
            WORK.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(cache, indent=0, ensure_ascii=False), encoding="utf-8")
            left = (time.time() - t0) / done * (len(todo) - i - 1)
            say(f"  음성 인식 {i + 1}/{len(todo)}  (남은 시간 약 {left / 60:.1f}분)")
    WORK.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(cache, indent=0, ensure_ascii=False), encoding="utf-8")


# ---- voice ------------------------------------------------------------------------

def scan_voice(folder: Path, max_s: float) -> list[dict]:
    files, _ = list_audio(folder)
    recs = []
    for p in files:
        rel = p.relative_to(folder).as_posix()
        st = p.stat()
        stem = p.stem
        r = {"rel": rel, "path": p, "size": st.st_size, "mtime": int(st.st_mtime), "stem": stem,
             "tokens": rm.name_tokens(stem) | {t for d in rel.split("/")[:-1] for t in rm.name_tokens(d)},
             "joined": re.sub(r"[^a-z0-9]", "", rel.lower()), "text": None, "q": 0.0, "why": [], "dur": 0.0, "peak": 0.0}
        try:
            x, sr = decode(p)
        except Exception as e:
            r["error"] = str(e)
            r["why"] = ["읽을 수 없음"]
            recs.append(r)
            continue
        m = ac.voice_metrics(x, sr)
        q, why = ac.voice_quality(m, sr, VOICE_MIN_S, max_s)
        if q > 0.0 and r["tokens"] & RADIO_WORDS:
            q, why = round(q * 0.5, 3), why + ["radio (name)"]
        r.update(m, sr=sr, q=q, why=why, hash=audio_hash(x))
        recs.append(r)
    return recs


def voice_targets(cfg: dict) -> list[dict]:
    """Every line the tool looks for: the table lines (with their N) and the extra phrases, each tied to
    one command sentence."""
    text_of = {}
    for e in cfg["table"]:
        for n in e["n"]:
            text_of[n] = e["text"]
    out = []
    for cmd, sentences in cfg["commands"].items():
        for i, s in enumerate(sentences):
            by_text: dict[str, list[int]] = defaultdict(list)
            for n in s["table"]:
                by_text[text_of[n]].append(n)
            for text, ns in by_text.items():
                out.append({"cmd": cmd, "i": i, "text": text, "table": True, "ns": ns})
            for text in s["phrases"]:
                out.append({"cmd": cmd, "i": i, "text": text, "table": False, "ns": []})
    return out


def match_voice(recs: list[dict], targets: list[dict], index_map: dict[int, str], match_min: float, asr: bool) -> None:
    """rec['match'] = the line a file says: {cmd, i, text, table, ns, sim, how}, or None."""
    by_n = {n: t for t in targets for n in t["ns"]}
    n_of = {rel: n for n, rel in index_map.items()}
    for r in recs:
        r["match"] = None
        if r["q"] <= 0.0:
            continue
        best = None
        heard = r.get("text")
        n = n_of.get(r["rel"])
        if heard is not None and not rm.words(heard):  # nothing spoken in it (or only [grunts])
            if n in by_n:
                t = by_n[n]
                r["match"] = {"cmd": t["cmd"], "i": t["i"], "text": t["text"], "table": True, "ns": t["ns"], "sim": 0.5, "how": "table?",
                              "unheard": True}
            continue
        if heard is not None:
            sim, t = max(((rm.similarity(heard, t["text"]), t) for t in targets), key=lambda st: (st[0], st[1]["table"]))
            if sim >= match_min:
                best = (t, sim, "asr-table" if t["table"] else "asr")
        if n is not None and n in by_n:
            t = by_n[n]
            if heard is None:
                best = (t, 0.9, "table")
            else:
                s = rm.similarity(heard, t["text"])
                if s >= match_min:
                    best = (t, s, "table+asr")
                elif best is None and s >= 0.5:
                    best = (t, s, "table?")
        if best is None and not asr:
            for t in targets:
                if rm.phrase_in_name(t["text"], r["tokens"], r["joined"]):
                    best = (t, 0.7, "name")
                    break
        if best:
            t, sim, how = best
            r["match"] = {"cmd": t["cmd"], "i": t["i"], "text": t["text"], "table": t["table"], "ns": t["ns"], "sim": round(sim, 3), "how": how}


def pin_voice(recs: list[dict], pins: dict) -> None:
    """Pinned voice files count as found for their sentence, whatever the matching said."""
    by_rel = {r["rel"]: r for r in recs}
    for cmd, sentences in pins.items():
        for i, files in enumerate(sentences):
            for rel in files:
                r = by_rel.get(rel)
                if r is not None and not r.get("error"):
                    r["match"] = {"cmd": cmd, "i": i, "text": r.get("text") or r["stem"], "table": False, "ns": [], "sim": 1.0, "how": "pin"}


def heard_before(r: dict) -> tuple[str, ...]:
    """What the processed take must still sound like: the untrimmed transcript or the line it was
    matched to (empty: nothing to check against)."""
    if not (r.get("text") and rm.words(r["text"])):
        return ()
    return (r["text"], r["match"]["text"]) if r.get("match") else (r["text"],)


def rank_key(r: dict) -> tuple:
    m = r["match"]
    return HOW_RANK[m["how"]], -m["sim"], -r["q"], r["rel"]


def plan_voice(recs: list[dict], cfg: dict, pins: dict | None = None) -> tuple[dict, dict]:
    """command -> per sentence the files for takes 0..3; plus command -> every usable file (the pool)."""
    usable = sorted((r for r in recs if r.get("match") and not r.get("bad")), key=rank_key)
    seen = {}
    plan, pools = {}, {}
    by_cmd: dict[str, list[dict]] = defaultdict(list)
    for r in usable:
        if r["hash"] in seen:
            r["dup_of"] = seen[r["hash"]]
            continue
        seen[r["hash"]] = r["rel"]
        by_cmd[r["match"]["cmd"]].append(r)
    ok = {r["rel"] for r in recs if r.get("match") and not r.get("bad")}
    for cmd, sentences in cfg["commands"].items():
        if pins and cmd in pins:  # exactly the pinned takes (minus the ones that failed the check)
            plan[cmd] = [[f for f in files if f in ok][:TAKES] for files in pins[cmd]]
            pools[cmd] = list(dict.fromkeys(f for files in pins[cmd] for f in files if f in ok))
            continue
        found = [r for r in by_cmd.get(cmd, []) if r["q"] >= POOR] or by_cmd.get(cmd, [])
        heard_texts = {r["match"]["text"] for r in found if not r["match"].get("unheard")}
        # a numbered file the recognizer heard no words in only stands in for a line nothing else says
        found = [r for r in found if not (r["match"].get("unheard") and r["match"]["text"] in heard_texts)]
        own = [[r["rel"] for r in found if r["match"]["i"] == i] for i in range(len(sentences))]
        per_text: dict[str, list[str]] = {}
        for r in found:
            per_text.setdefault(r["match"]["text"], []).append(r["rel"])
        lists = list(per_text.values())
        pool = [lst[k] for k in range(max((len(x) for x in lists), default=0)) for lst in lists if k < len(lst)]
        plan[cmd] = rm.distribute(own, pool, TAKES)
        pools[cmd] = pool
    return plan, pools


def voice_take(x: np.ndarray, sr: int) -> np.ndarray:
    """Recorded line -> game file: quiet before / after cut, rumble removed, loudness evened out
    (the same chain as voice.py process), short fades so it never clicks."""
    y = ac.level_voice(ac.highpass(ac.trim_silence(x, sr), sr, 90.0))
    return ac.fade_out(ac.fade_in(y, sr, 0.004), sr, 0.03)


class VoiceChecker:
    """Processes a voice file and says what is wrong with the result; listens again when speech
    recognition is on (the trimmed line must still sound like the untrimmed one). Cached per file."""

    def __init__(self, run, match_min: float, max_s: float):
        self.run, self.match_min, self.max_s = run, match_min, max_s
        self.cache: dict[str, tuple[np.ndarray, int, list[str], str]] = {}

    def __call__(self, r: dict, expect: tuple[str, ...], min_s: float = VOICE_MIN_S, max_s: float | None = None) -> tuple[np.ndarray, int, list[str]]:
        key = r["rel"] + "|" + "|".join(expect)
        if key not in self.cache:
            x, sr = decode(r["path"])
            y = voice_take(x, sr)
            probs = ac.audio_problems(y, sr, min_s, max_s or self.max_s)
            heard = ""
            if not probs and self.run and expect:
                heard = self.run(to16k(y, sr))[0]
                if max(rm.similarity(heard, e) for e in expect) < self.match_min:
                    probs.append(f"가공 뒤 다르게 들림: \"{heard}\"")
            self.cache[key] = (y, sr, probs, heard)
        y, sr, probs, _ = self.cache[key]
        return y, sr, probs


def apply_voice(recs: list[dict], cfg: dict, check: VoiceChecker, backup: Backup, dry: bool, pins: dict | None = None) -> dict:
    """Writes voice_<command>_<line>_<take>.wav for every command with found lines. A take that fails
    the check is dropped and the plan is made again without it, until every written take is good."""
    by_rel = {r["rel"]: r for r in recs}
    fixes = []
    for _ in range(200):
        plan, pools = plan_voice(recs, cfg, pins)
        bad = []
        for cmd, slots in plan.items():
            for slot in slots:
                for rel in slot:
                    r = by_rel[rel]
                    _, _, probs = check(r, heard_before(r))
                    if probs:
                        bad.append((r, probs))
        if not bad:
            break
        for r, probs in bad:
            if not r.get("bad"):
                r["bad"] = probs
                fixes.append({"file": r["rel"], "line": r["match"]["text"], "problems": probs})
    written = []
    for cmd, slots in plan.items():
        if not any(slots):
            continue  # nothing found for this command: its current files stay
        for old in ac.AUDIO.glob(f"voice_{cmd}_*_*.wav"):
            backup.keep(old)
            if not dry:
                remove_game_file(old)
        for i, slot in enumerate(slots):
            t = 0
            for rel in slot:
                r = by_rel[rel]
                y, sr, probs = check(r, heard_before(r))
                if probs:
                    continue  # only when the replace rounds ran out: never write a failing take
                name = f"voice_{cmd}_{i}_{t}.wav"
                t += 1
                if not dry:
                    ac.write_wav(ac.AUDIO / name, y, sr)
                written.append({"file": name, "cmd": cmd, "i": i, "take": t - 1, "source": rel, "line": r["match"]["text"],
                                "how": r["match"]["how"], "sim": r["match"]["sim"], "q": r["q"], "heard": r.get("text")})
    return {"plan": plan, "pools": pools, "written": written, "fixes": fixes}


def pick_hurt(recs: list[dict], hcfg: dict, match_min: float) -> list[dict]:
    """Short pain sounds of the officer: by file name, or heard as "I'm hit" / [grunts]."""
    out = []
    names = set(hcfg["name_tokens"])
    for r in recs:
        if r.get("error") or r.get("match") or not (hcfg["min_s"] <= r["dur"] <= hcfg["max_s"]) or r["peak"] < 0.003:
            continue
        how = None
        if r["tokens"] & names:
            how = "name"
        heard = r.get("text")
        if heard is not None:
            if max((rm.similarity(heard, p) for p in hcfg["phrases"]), default=0.0) >= match_min:
                how = how or "asr"
            elif any(d in m for m in rm.noise_marks(heard) for d in hcfg["descriptors"]) and len(rm.words(heard)) <= 2:
                how = how or "asr"
            elif how == "name" and len(rm.words(heard)) > 3:
                how = None  # named like pain but says a whole sentence
        if how:
            q = 0.5 if r["clip"] > 0.001 else 1.0
            out.append({**r, "hurt_how": how, "hurt_q": q})
    out.sort(key=lambda r: (r["hurt_how"] != "name", -r["hurt_q"], r["rel"]))
    seen, uniq = set(), []
    for r in out:
        if r["hash"] not in seen:
            seen.add(r["hash"])
            uniq.append(r)
    return uniq


def apply_hurt(cands: list[dict], hcfg: dict, check: VoiceChecker, backup: Backup, dry: bool) -> dict:
    chosen, fixes = [], []
    for r in cands:
        if len(chosen) >= int(hcfg["keep"]):
            break
        y, sr, probs = check(r, (), float(hcfg["min_s"]) * 0.5, float(hcfg["max_s"]) + 0.5)
        if probs:
            fixes.append({"file": r["rel"], "problems": probs})
            continue
        chosen.append((r, y, sr))
    if chosen:
        for old in ac.AUDIO.glob("hurt_*.wav"):
            backup.keep(old)
            if not dry:
                remove_game_file(old)
        for n, (r, y, sr) in enumerate(chosen):
            if not dry:
                ac.write_wav(ac.AUDIO / f"hurt_{n}.wav", y, sr)
    return {"written": [{"file": f"hurt_{n}.wav", "source": r["rel"], "how": r["hurt_how"], "heard": r.get("text")}
                        for n, (r, _, _) in enumerate(chosen)], "fixes": fixes}


# ---- weapons ----------------------------------------------------------------------

def scan_weapons(folder: Path, wcfg: dict) -> list[dict]:
    files, _ = list_audio(folder)
    recs = []
    for p in files:
        rel = p.relative_to(folder).as_posix()
        r = {"rel": rel, "path": p, **rm.weapon_info(rel, wcfg), "dur": 0.0, "peak": 0.0, "problems": []}
        try:
            x, sr = decode(p)
            r.update(sr=sr, dur=round(len(x) / sr, 3), peak=round(float(np.abs(x).max()) if len(x) else 0.0, 4), hash=audio_hash(x))
            r["problems"] = [w for w in ac.audio_problems(x, sr, 0.03, 12.0, silent_peak=0.003) if w not in ("DC offset", "clipped")]
        except Exception as e:
            r["problems"] = ["읽을 수 없음"]
            r["error"] = str(e)
        recs.append(r)
    return recs


def weapon_candidates(recs: list[dict], key: str, kcfg: dict, wcfg: dict, cat: dict) -> tuple[list[dict], bool]:
    """Scored candidates of one game sound (best first) and whether a fallback gun type was used."""
    want = ac.sound_cfg(cat, key)["want"]
    lo, hi = float(kcfg.get("min_s", 0.05)), float(kcfg.get("max_s", 8.0))

    def pick(classes: list[str]) -> list[dict]:
        return [r for r in recs if r["layer"] == kcfg["layer"] and not r["excluded"] and not r["problems"]
                and (not classes or r["class"] in classes) and lo <= r["dur"] <= hi]

    cands, fallback = pick(kcfg["class"]), False
    if not cands and kcfg.get("fallback_class"):
        cands, fallback = pick(kcfg["fallback_class"]), True
    out = []
    order = kcfg["class"] or [""]
    for r in cands:
        x, sr = decode(r["path"])
        a = ac.analyze(x, sr, want)
        bonus = rm.preference(r["tokens"], wcfg["prefer"]) + (0.03 if r["class"] == order[0] else 0.0)
        out.append({**r, "analysis": a, "score": round(float(a["score"]) + bonus, 3)})
    out.sort(key=lambda c: (-c["score"], c["rel"]))
    return out, fallback


def choose_takes(cands: list[dict], keep: int, min_score: float, prefer_weapon: str | None = None) -> tuple[list[dict], list[dict], dict]:
    """The takes of the one gun (file group) that scores best, so a burst does not jump between guns;
    with fewer than 3 good takes, the same gun's other groups and then other guns fill up."""
    good, seen = [], set()
    for c in cands:
        if c["score"] >= min_score and c.get("hash") not in seen:
            seen.add(c.get("hash"))
            good.append(c)
    groups: dict[str, list[dict]] = defaultdict(list)
    for c in good:
        groups[c["group"]].append(c)

    def gscore(g: list[dict]) -> float:
        top = sorted((c["score"] for c in g), reverse=True)[:3]
        return float(np.mean(top)) * (0.85 + 0.05 * min(len(g), 3)) + (0.2 if prefer_weapon and g[0]["weapon"] == prefer_weapon else 0.0)

    order = sorted(groups.values(), key=lambda g: (-gscore(g), g[0]["group"]))
    if not order:
        return [], [], {}
    first = order[0]
    top = first[0]["score"]
    steady = [c for c in first if c["score"] >= top - OUTLIER]  # a take far below its siblings is a bad one (two bangs, late start)
    chosen = (steady if len(steady) >= min(2, len(first)) else first)[:keep]
    if len(chosen) < min(3, keep):
        rest = sorted((c for g in order[1:] for c in g), key=lambda c: (c["weapon"] != first[0]["weapon"], -c["score"], c["rel"]))
        chosen = chosen + rest[: min(3, keep) - len(chosen)]
    ids = {c["rel"] for c in chosen}
    alternates = sorted((c for c in good if c["rel"] not in ids), key=lambda c: (c["weapon"] != first[0]["weapon"], -c["score"], c["rel"]))
    return chosen, alternates, {"group": first[0]["group"], "weapon": first[0]["weapon"], "group_score": round(gscore(first), 3)}


def compose_reloads(recs: list[dict], kcfg: dict, wcfg: dict, cat: dict, keep: int) -> list[dict]:
    """Full reloads put together from parts of one gun: magazine out, magazine in, bolt / slide."""
    at = wcfg["reload_parts_at_s"]
    want = cat["kinds"]["foley"]
    parts: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for r in recs:
        if r["layer"] in at and not r["excluded"] and not r["problems"] and r["dur"] <= 1.5 and (not kcfg["class"] or r["class"] in kcfg["class"]):
            x, sr = decode(r["path"])
            parts[r["weapon"]][r["layer"]].append({**r, "score": float(ac.analyze(x, sr, want)["score"])})
    order = kcfg["class"] or [""]
    guns = [(w, p) for w, p in parts.items() if p.get("mag_out") and p.get("mag_in")]
    guns.sort(key=lambda wp: (order.index(wp[1]["mag_in"][0]["class"]) if wp[1]["mag_in"][0]["class"] in order else 9,
                              not wp[1].get("bolt"), wp[0]))
    out = []
    for weapon, p in guns:
        for k in p:
            p[k].sort(key=lambda c: (-c["score"], c["rel"]))
        for v in range(min(keep - len(out), max(len(lst) for lst in p.values()))):
            pieces = [(name, p[name][v % len(p[name])]) for name in ("mag_out", "mag_in", "bolt") if p.get(name)]
            mix, sr = mix_parts([(c["path"], float(at[name]), 0.7) for name, c in pieces])
            out.append({"rel": " + ".join(c["rel"] for _, c in pieces), "mix": (mix, sr), "weapon": weapon, "group": "mix:" + weapon,
                        "class": pieces[0][1]["class"], "score": round(float(np.mean([c["score"] for _, c in pieces])), 3),
                        "hash": audio_hash(mix), "analysis": ac.analyze(mix, sr, ac.sound_cfg(cat, "reload")["want"])})
        if len(out) >= keep:
            break
    return out


def pinned_takes(items: list, by_rel: dict[str, dict]) -> list[dict]:
    """pins.json weapon entries -> takes: a file name, or a list of [file, at_s, peak] mixed into one take.
    A name that is not in the folder drops its take."""
    out = []
    for item in items:
        if isinstance(item, str):
            if item in by_rel and not by_rel[item]["problems"]:
                out.append({**by_rel[item], "score": 1.0, "analysis": {}})
        elif all(part[0] in by_rel for part in item):
            mix, sr = mix_parts([(by_rel[f]["path"], at, peak) for f, at, peak in item])
            out.append({"rel": " + ".join(part[0] for part in item), "mix": (mix, sr), "weapon": "pin", "group": "pin", "class": "",
                        "score": 1.0, "hash": audio_hash(mix), "analysis": {}})
    return out


def stage_raw(key: str, c: dict, dry: bool) -> Path:
    """Copies a candidate into _raw/<key>/ron_*.wav (mono) so the take-picking tool lists it next to
    the generated takes; returns the copy (or the source in a dry run)."""
    name = f"ron_{safe_name(c['rel'].rsplit('.', 1)[0] if 'mix' not in c else 'reload_mix_' + c['hash'])}.wav"
    out = ac.RAW / key / name
    if dry:
        return Path(c["path"]) if "path" in c else out
    if not out.exists():
        x, sr = c["mix"] if "mix" in c else decode(c["path"])
        ac.write_wav(out, x, sr)
    return out


def update_audition(key: str, staged: dict[str, dict], chosen: list[str]) -> None:
    """The take-picking tool shows the imported takes with the chosen ones marked 'use', so what it
    shows is what the game plays (G there rebuilds the sound from these marks)."""
    rank_path = ac.RAW / key / "ranking.json"
    rows = json.loads(rank_path.read_text(encoding="utf-8")) if rank_path.exists() else []
    rows = [r for r in rows if not str(r.get("file", "")).startswith("ron_")]
    for name, c in staged.items():
        a = c.get("analysis", {})
        rows.append({"file": name, "score": c["score"], "onset_s": a.get("onset_s", 0.0), "events": a.get("events", 0),
                     "centroid_hz": a.get("centroid_hz", 0), "origin": c["rel"]})
    rows.sort(key=lambda r: r.get("score", 0.0), reverse=True)
    rank_path.write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
    pick_dir = ac.PICK / key
    if pick_dir.is_dir():
        for p in pick_dir.glob("*.wav"):
            p.unlink()
    pick_dir.mkdir(parents=True, exist_ok=True)
    for name in chosen:
        shutil.copy(ac.RAW / key / name, pick_dir / name)
    dec_path = ac.PICK / "decisions.json"
    dec = json.loads(dec_path.read_text(encoding="utf-8")) if dec_path.exists() else {}
    dec = {k: v for k, v in dec.items() if not k.startswith(key + "/")}
    dec.update({f"{key}/{name}": "use" for name in chosen})
    dec_path.write_text(json.dumps(dec, indent=2, ensure_ascii=False), encoding="utf-8")


def clear_audition(key: str) -> None:
    """No picks for `key`: G in the take-picking tool then leaves its (processed-far) files alone."""
    pick_dir = ac.PICK / key
    if pick_dir.is_dir():
        for p in pick_dir.glob("*.wav"):
            p.unlink()
    dec_path = ac.PICK / "decisions.json"
    if dec_path.exists():
        dec = json.loads(dec_path.read_text(encoding="utf-8"))
        dec_path.write_text(json.dumps({k: v for k, v in dec.items() if not k.startswith(key + "/")}, indent=2, ensure_ascii=False), encoding="utf-8")


def game_bounds(key: str, cat: dict) -> tuple[float, float]:
    cfg = ac.sound_cfg(cat, key)
    return 0.05, float(cfg.get("tail_s", cfg["seconds"])) + 0.6


def apply_weapon_key(key: str, chosen: list[dict], alternates: list[dict], cat: dict, backup: Backup, dry: bool) -> dict:
    """Processes the chosen takes like process.py and checks every result; a failing take is swapped
    for the next alternate (or dropped). Then writes <key>_<n>.wav."""
    cfg = ac.sound_cfg(cat, key)
    lo, hi = game_bounds(key, cat)
    chosen, alternates = list(chosen), list(alternates)
    fixes = []
    results = []
    while True:
        results, bad = [], None
        for c in chosen:
            x, sr = c["mix"] if "mix" in c else decode(c["path"])
            y = process.process_one(x, sr, cfg)
            probs = ac.audio_problems(y, sr, lo, hi)
            if probs:
                bad = (c, probs)
                break
            results.append((c, y, sr))
        if bad is None:
            break
        c, probs = bad
        fixes.append({"file": c["rel"], "problems": probs})
        i = chosen.index(c)
        if alternates:
            chosen[i] = alternates.pop(0)
        else:
            chosen.pop(i)
    if not chosen:
        return {"written": [], "fixes": fixes}
    for old in process.numbered(key):
        backup.keep(old)
    backup.keep(process.MANIFEST)
    backup.keep(ac.PICK / "decisions.json")
    backup.keep(ac.RAW / key / "ranking.json")
    written = []
    if not dry:
        staged = {}
        for c in chosen + alternates[: max(MAX_VARIANTS - len(chosen), 0)]:
            staged[stage_raw(key, c, dry).name] = c
        raw = [stage_raw(key, c, dry) for c in chosen]
        for old in process.numbered(key):
            remove_game_file(old)
        outs = process.process_key(key, cfg, raw, replace=True)
        manifest = json.loads(process.MANIFEST.read_text(encoding="utf-8"))
        for entry, c in zip(manifest[key], chosen):
            entry["origin"] = c["rel"]
        process.MANIFEST.write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
        update_audition(key, staged, [p.name for p in raw])
        written = [p.name for p in outs]
    else:
        written = [f"{key}_{n}.wav" for n in range(len(chosen))]
    return {"written": written, "fixes": fixes, "sources": [c["rel"] for c in chosen],
            "scores": [c["score"] for c in chosen]}


def apply_far_dsp(dst: str, src: str, backup: Backup, dry: bool) -> list[str]:
    """No far takes in the folder: the far set is made from the new close game files (make_far.py)."""
    files = process.numbered(src)
    for old in process.numbered(dst):
        backup.keep(old)
        if not dry:
            remove_game_file(old)
    out = []
    for n, p in enumerate(files):
        if not dry:
            x, sr = ac.read_mono(p)
            ac.write_wav(ac.AUDIO / f"{dst}_{n}.wav", far_take(x, sr), sr)
        out.append(f"{dst}_{n}.wav")
    if not dry:
        manifest = json.loads(process.MANIFEST.read_text(encoding="utf-8")) if process.MANIFEST.exists() else {}
        manifest[dst] = [{"file": f, "source": f"{src}_{n}.wav", "made_by": "make_far.far_take"} for n, f in enumerate(out)]
        backup.keep(ac.PICK / "decisions.json")
        backup.keep(process.MANIFEST)
        process.MANIFEST.write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
        clear_audition(dst)
    return out


# ---- checking every game file -----------------------------------------------------------

def bounds_for(name: str, cat: dict) -> tuple[float, float]:
    stem = name.rsplit(".", 1)[0]
    if stem.startswith("voice_"):
        return VOICE_MIN_S * 0.8, 8.0
    if stem.startswith("hurt_"):
        return 0.05, 3.0
    if stem.startswith("scream_"):
        return 0.15, 6.0
    key = re.sub(r"_\d+$", "", stem)
    if key == "hum":
        return 2.0, 90.0
    if key in cat["sounds"]:
        return game_bounds(key, cat)
    return 0.03, 30.0


def verify_all(cat: dict, fix: bool, backup: Backup | None) -> list[dict]:
    """Every game file in assets/audio: readable, not empty, not silent, sane length, not clipped.
    With fix=True a bad file is moved to the backup folder, so the game falls back to its other
    takes or the synthesized sound instead of playing silence."""
    out = []
    for p in sorted(ac.AUDIO.glob("*.wav")):
        lo, hi = bounds_for(p.name, cat)
        try:
            x, sr = ac.read_mono(p)
            probs = ac.audio_problems(x, sr, lo, hi)
        except Exception as e:
            probs = [f"읽을 수 없음: {e}"]
        if probs:
            out.append({"file": p.name, "problems": probs, "removed": False})
            if fix and backup is not None:
                backup.dry = False
                backup.keep(p)
                remove_game_file(p)
                out[-1]["removed"] = True
    return out


# ---- report ---------------------------------------------------------------------------

def write_report(ctx: dict) -> Path:
    WORK.mkdir(parents=True, exist_ok=True)
    L = ["# Ready or Not 소리 가져오기 결과", "", f"- 실행: {ctx['time']}" + ("  (**미리보기: 게임 파일은 바뀌지 않음**)" if ctx["dry"] else ""),
         f"- 대사 폴더: `{ctx.get('voice_dir', '-')}`", f"- 무기 폴더: `{ctx.get('weapons_dir', '-')}`",
         f"- 음성 인식: {ctx.get('asr', '사용 안 함')}"]
    if ctx.get("backup"):
        L.append(f"- 바뀌기 전 파일 백업: `assets/audio/_backup/{ctx['backup']}/` ({ctx['backup_n']}개)")
    for w in ctx.get("warnings", []):
        L.append(f"- **주의**: {w}")
    v = ctx.get("voice")
    if v:
        L += ["", "## 대사", "", f"파일 {v['files']}개 (확장자: {v['exts']}), 읽을 수 없는 파일 {v['unreadable']}개, 쓸 수 없는 품질 {v['unusable']}개."]
        if v["index"]:
            i = v["index"]
            L.append(f"대사 표 번호와 맞는 파일 묶음: `{i['group']}` ({i['files']}개, {i['base']}번부터 시작, 표 {i['covered']}줄 맞음)")
        else:
            L.append("대사 표 번호(N)와 맞는 번호 묶음은 찾지 못했습니다.")
        L += ["", "### 대사 표 (N)", "", "| N | 대사 | 찾은 파일 | 방법 | 들린 문장 | 들어간 곳 |", "|---|---|---|---|---|---|"]
        for row in v["table_rows"]:
            L.append(f"| {row['n']} | {row['text']} | {row['file'] or '**못 찾음**'} | {row['how']} | {row['heard']} | {row['used']} |")
        L += ["", "### 명령 문장별 테이크", ""]
        for cmd, sentences in v["commands"].items():
            for s in sentences:
                L.append(f"- **{s['ko']}** (`voice_{cmd}_{s['i']}_*`)")
                if not s["takes"]:
                    L.append("  - (없음: 기존 파일 또는 합성음 유지)")
                for t in s["takes"]:
                    L.append(f"  - 테이크 {t['take']}: `{t['source']}` — \"{t['line']}\" ({HOW_KO.get(t['how'], t['how'])}, 일치 {t['sim']:.2f}, 품질 {t['q']:.2f})")
        if v["extra_found"]:
            L += ["", f"표 밖에서 같은 뜻으로 찾은 대사 {len(v['extra_found'])}개: " + ", ".join(f"\"{t}\"" for t in v["extra_found"])]
        if v["unused"]:
            L += ["", f"찾았지만 자리가 모자라 안 쓴 파일 {len(v['unused'])}개: " + ", ".join(f"`{u}`" for u in v["unused"][:30])]
        if v["fixes"]:
            L += ["", "### 검사에서 걸려 다른 파일로 바꾼 대사", ""]
            for f in v["fixes"]:
                L.append(f"- `{f['file']}` (\"{f['line']}\"): {', '.join(f['problems'])}")
        if v.get("hurt"):
            h = v["hurt"]
            L += ["", "### 신음 (총에 맞았을 때, hurt_<n>.wav)", ""]
            L += [f"- `{w['file']}` ← `{w['source']}` ({HOW_KO.get(w['how'], w['how'])}{', 들림: ' + repr(w['heard']) if w['heard'] else ''})" for w in h["written"]] or ["- 찾지 못함 (기존 유지)"]
    w = ctx.get("weapons")
    if w:
        L += ["", "## 무기 소리", "", f"파일 {w['files']}개 (확장자: {w['exts']}), 읽을 수 없는 파일 {w['unreadable']}개.",
              "이름으로 나눈 결과: " + ", ".join(f"{k} {n}" for k, n in w["classes"].items()), ""]
        for key, k in w["keys"].items():
            L.append(f"### {key}")
            if k.get("note"):
                L.append(k["note"])
            for i, (src, sc) in enumerate(zip(k.get("sources", []), k.get("scores", []))):
                L.append(f"- `{key}_{i}.wav` ← `{src}` (점수 {sc:.2f})")
            for f in k.get("fixes", []):
                L.append(f"- 검사에서 걸려 바꿈: `{f['file']}`: {', '.join(f['problems'])}")
            L.append("")
    chk = ctx.get("verify")
    if chk is not None:
        L += ["", "## 최종 검사 (assets/audio 전체)", ""]
        if not chk:
            L.append("모든 게임 소리 파일이 정상입니다 (비어 있음, 무음, 길이, 찌그러짐, 직류 성분 검사).")
        for c in chk:
            L.append(f"- `{c['file']}`: {', '.join(c['problems'])}" + (" → 치움 (백업에 있음)" if c["removed"] else ""))
    if ctx.get("godot"):
        L += ["", f"Godot 가져오기: {ctx['godot']}"]
    L += ["", "## 다음에 할 일", "", "- 게임 실행 후 **1~4** 명령으로 대사를, **F7** 소리 시험 창으로 총소리를 들어 보세요.",
          "- 총소리를 귀로 바꾸려면 `tools/audio/pick_sounds.bat` (가져온 후보가 `ron_`으로 시작, 지금 쓰는 것은 '사용'으로 표시됨) 후 **G**.",
          "- 대사 배정은 `tools/audio/import_ron.json`의 `commands`에서 바꾸고 다시 실행하면 됩니다.",
          "- 결과가 이상하면 `assets/audio/_import/inventory.csv`를 보내 주세요 (파일마다 들린 문장과 분류가 있음).", ""]
    path = WORK / "REPORT.md"
    path.write_text("\n".join(L), encoding="utf-8")
    return path


def write_inventory(voice: list[dict], weapons: list[dict], used: dict[str, str]) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    with open(WORK / "inventory.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["folder", "file", "seconds", "peak", "quality_or_score", "problems", "heard", "matched_line", "command", "sentence",
                    "how", "similarity", "class", "layer", "weapon", "used_as"])
        for r in voice:
            m = r.get("match") or {}
            w.writerow(["voice", r["rel"], r["dur"], r["peak"], r["q"], "; ".join(r.get("why", []) + (r.get("bad") or [])), r.get("text") or "",
                        m.get("text", ""), m.get("cmd", ""), m.get("i", ""), m.get("how", ""), m.get("sim", ""), "", "", "", used.get("v:" + r["rel"], "")])
        for r in weapons:
            w.writerow(["weapons", r["rel"], r["dur"], r["peak"], r.get("score", ""), "; ".join(r["problems"] + [f"excluded: {','.join(r['excluded'])}"] if r["excluded"] else r["problems"]),
                        "", "", "", "", "", "", r["class"], r["layer"], r["weapon"], used.get("w:" + r["rel"], "")])


# ---- main ----------------------------------------------------------------------------------

def run_voice(cfg: dict, folder: Path, args, backup: Backup, ctx: dict, used: dict) -> list[dict]:
    acfg = cfg["asr"]
    say(f"[대사] {folder} 살펴보는 중...")
    files, exts = list_audio(folder)
    recs = scan_voice(folder, float(acfg["max_s"]))
    say(f"  파일 {len(recs)}개")
    if not recs:
        ctx["warnings"].append(f"대사 폴더에 소리 파일이 없습니다 (확장자: {dict(exts)}). FModel에서 소리를 wav/ogg로 내보냈는지 확인하세요.")
        return recs
    raw_only = [r for r in recs if r["rel"].lower().endswith((".bank", ".fsb", ".wem", ".binka")) and r.get("error")]
    if raw_only:
        ctx["warnings"].append(f"읽을 수 없는 게임 원본 형식 {len(raw_only)}개(.bank/.fsb/.wem/.binka): 무기처럼 Fmod_Bank_Tools 등으로 wav로 바꾼 폴더를 지정하세요.")
    run = None
    if not args.no_asr:
        say(f"  음성 인식 준비 ({acfg['model']})...")
        run, desc = load_asr(args.asr_model or acfg["model"])
        if run:
            ctx["asr"] = desc
            say(f"  {desc}")
            transcribe(recs, run, desc, float(acfg["max_s"]))
        else:
            ctx["asr"] = f"없음 ({desc})"
            ctx["warnings"].append("음성 인식 없이 진행했습니다: 대사 표 번호와 파일 이름으로만 찾았습니다. "
                                   "정확하게 하려면 `pip install faster-whisper` 후 다시 실행하세요 (import_ron.bat이 자동으로 설치).")
            say("  음성 인식 없음: 표 번호와 파일 이름으로 찾습니다")
    targets = voice_targets(cfg)
    table_ns = [n for e in cfg["table"] for n in e["n"]]
    index_map, index_info = rm.table_group([r["rel"] for r in recs], table_ns, cfg["table_hint"])
    if index_info and index_info["files"] > 2 * len(set(table_ns)) and not index_info["hint"]:
        ctx["warnings"].append(f"대사 표 번호를 맞춘 묶음 `{index_info['group']}`이 표보다 훨씬 큽니다({index_info['files']}개): "
                               "음성 인식이 없으면 번호가 다른 대사를 가리킬 수 있습니다.")
    match_voice(recs, targets, index_map, float(acfg["match_min"]), run is not None)
    pins = load_pins()
    pin_voice(recs, pins.get("voice", {}))
    by_rel = {r["rel"]: r for r in recs}
    check = VoiceChecker(run, float(acfg["match_min"]), float(acfg["max_s"]) + 0.5)
    res = apply_voice(recs, cfg, check, backup, args.dry_run, pins.get("voice"))
    hurt = None
    if cfg.get("hurt"):
        cands, hcfg = pick_hurt(recs, cfg["hurt"], float(acfg["match_min"])), cfg["hurt"]
        if pins.get("hurt"):
            cands = [{**by_rel[f], "hurt_how": "pin"} for f in pins["hurt"] if f in by_rel and not by_rel[f].get("error")]
            hcfg = {**hcfg, "keep": len(cands)}
        hurt = apply_hurt(cands, hcfg, check, backup, args.dry_run)
        for w in hurt["written"]:
            used["v:" + w["source"]] = w["file"]
    for w in res["written"]:
        used["v:" + w["source"]] = (used.get("v:" + w["source"], "") + " " + w["file"]).strip()
    # what happened to every table line
    text_of = {n: e["text"] for e in cfg["table"] for n in e["n"]}
    rows = []
    for n in sorted(text_of):
        own = by_rel.get(index_map.get(n, ""))
        note = ""
        if own is not None and own.get("match") and n in own["match"]["ns"]:
            r = own
        else:
            if own is not None:
                note = f"번호 {n} 파일 `{own['rel']}`: " + (", ".join(own.get("why") or []) or (f"다른 대사로 들림 \"{own.get('text')}\"" if own.get("text") else "쓸 수 없음"))
            found = sorted((x for x in recs if x.get("match") and x["match"]["text"] == text_of[n]), key=rank_key)
            r = found[0] if found else None
            if r is not None and note:
                note += f" → 같은 대사 `{r['rel']}`로 대신함"
        used_as = used.get("v:" + r["rel"], "안 씀") if r else "-"
        if r is not None and r.get("dup_of") and "v:" + r["rel"] not in used:
            used_as = f"`{r['dup_of']}`와 똑같은 소리라 그 파일로 들어감"
        rows.append({"n": n, "text": text_of[n], "file": f"`{r['rel']}`" if r else "", "how": HOW_KO.get(r["match"]["how"], "") if r else "",
                     "heard": (r.get("text") or "") if r else "", "used": used_as + (f" ({note})" if note else "")})
    ko_lines = json.loads(COMMANDS.read_text(encoding="utf-8"))
    commands = {}
    for cmd, sentences in cfg["commands"].items():
        game = ko_lines.get(cmd, [])
        if len(game) != len(sentences) or any(s.get("ko") and s["ko"] != g for s, g in zip(sentences, game)):
            ctx["warnings"].append(f"import_ron.json의 {cmd} 문장이 data/commands.json과 다릅니다: 순서(번호)대로 넣었습니다.")
        commands[cmd] = [{"ko": game[i] if i < len(game) else s.get("ko", ""), "i": i,
                          "takes": [w for w in res["written"] if w["cmd"] == cmd and w["i"] == i]} for i, s in enumerate(sentences)]
    used_rels = {w["source"] for w in res["written"]}
    unused = [rel for pool in res["pools"].values() for rel in pool if rel not in used_rels]
    extra = sorted({by_rel[w["source"]]["match"]["text"] for w in res["written"] if not by_rel[w["source"]]["match"]["table"]})
    ctx["voice"] = {"files": len(recs), "exts": dict(exts), "unreadable": sum(1 for r in recs if r.get("error")),
                    "unusable": sum(1 for r in recs if not r.get("error") and r["q"] <= 0), "index": index_info, "table_rows": rows,
                    "commands": commands, "fixes": res["fixes"], "unused": unused, "extra_found": extra, "hurt": hurt}
    n_written = len(res["written"])
    say(f"  대사 파일 {n_written}개 {'(미리보기)' if args.dry_run else '작성'}; 표 {sum(1 for r in rows if r['file'])}/{len(rows)}줄 찾음; "
        f"검사에서 바꾼 것 {len(res['fixes'])}개")
    return recs


def run_weapons(cfg: dict, folder: Path, args, cat: dict, backup: Backup, ctx: dict, used: dict) -> list[dict]:
    wcfg = cfg["weapons"]
    say(f"[무기] {folder} 살펴보는 중...")
    _, exts = list_audio(folder)
    recs = scan_weapons(folder, wcfg)
    say(f"  파일 {len(recs)}개")
    if not recs:
        ctx["warnings"].append(f"무기 폴더에 소리 파일이 없습니다 (확장자: {dict(exts)}).")
        return recs
    classes = Counter(f"{r['class'] or '?'}/{r['layer']}" for r in recs if not r["problems"])
    readable = [r for r in recs if not r["problems"]]
    if readable and sum(1 for r in readable if r["class"] or r["layer"] not in ("other", "shot")) < 0.05 * len(readable):
        n = stage_unnamed(readable, cat, args.dry_run)
        ctx["warnings"].append(f"무기 파일 이름에 총 종류나 소리 층 정보가 거의 없어 자동으로 고르지 않았습니다. 총소리처럼 들리는 후보 {n}개를 "
                               "소리 고르기 프로그램(pick_sounds.bat)의 rifle / pistol 목록에 넣었으니 귀로 골라 G를 누르세요.")
        ctx["weapons"] = {"files": len(recs), "exts": dict(exts), "unreadable": sum(1 for r in recs if r.get("error")),
                          "classes": dict(classes.most_common(20)), "keys": {}}
        return recs
    keys_out = {}
    chosen_weapon = {}
    by_rel = {r["rel"]: r for r in recs}
    pins = load_pins().get("weapons", {})
    for key, kcfg in wcfg["keys"].items():
        if key not in cat["sounds"]:
            continue
        if key in pins:
            chosen = pinned_takes(pins[key], by_rel)
            if not chosen:
                keys_out[key] = {"note": "직접 지정(pins.json): 쓸 파일이 없어 그대로 둡니다."}
                continue
            res = apply_weapon_key(key, chosen, [], cat, backup, args.dry_run)
            if res["written"]:
                chosen_weapon[key] = chosen[0].get("weapon")
            keys_out[key] = {**res, "note": "직접 지정(pins.json)."}
            for src, f in zip(res.get("sources", []), res["written"]):
                for part in src.split(" + "):
                    used["w:" + part] = (used.get("w:" + part, "") + " " + f).strip()
            say(f"  {key}: {len(res['written'])}개 (직접 지정){' 바꿈 ' + str(len(res['fixes'])) if res['fixes'] else ''}")
            continue
        min_score = float(kcfg.get("min_score", wcfg["min_score"] - (0.1 if kcfg["layer"] == "far" else 0.0)))
        cands, fallback = weapon_candidates(recs, key, kcfg, wcfg, cat)
        for c in cands:
            by_rel[c["rel"]]["score"] = c["score"]
        pair = kcfg.get("pair")
        if pair and pair not in chosen_weapon:
            keys_out[key] = {"note": f"`{pair}`를 가져오지 않아 그대로 둡니다."}
            continue
        chosen, alternates, info = choose_takes(cands, int(kcfg["keep"]), min_score, chosen_weapon.get(pair))
        note = ""
        if key == "reload" and len(chosen) < 2:
            mixes = compose_reloads(recs, kcfg, wcfg, cat, int(kcfg["keep"]))
            if mixes:
                chosen, alternates = mixes, []
                note = "통째 재장전 소리가 없어 탄창 빼기 / 넣기 / 노리쇠 소리를 이어 붙였습니다."
        if not chosen:
            if pair and kcfg["layer"] == "far":
                files = apply_far_dsp(key, pair, backup, args.dry_run)
                keys_out[key] = {"note": f"멀리서 들리는 녹음이 없어 새 `{pair}` 소리를 가공해 만들었습니다 ({len(files)}개)."}
                say(f"  {key}: {pair}에서 가공 {len(files)}개")
            else:
                keys_out[key] = {"note": f"맞는 파일이 없어 기존 소리를 그대로 둡니다 (후보 {len(cands)}개, 기준 {min_score:.2f} 이상 없음)."}
                say(f"  {key}: 찾지 못함 (기존 유지)")
            continue
        if fallback:
            note = (note + " " if note else "") + f"{'/'.join(kcfg['class'])} 소리가 없어 {'/'.join(kcfg['fallback_class'])} 소리를 썼습니다."
        res = apply_weapon_key(key, chosen, alternates, cat, backup, args.dry_run)
        if res["written"]:
            chosen_weapon[key] = info.get("weapon") or (chosen[0].get("weapon") if chosen else None)
        if info:
            note = (note + " " if note else "") + f"고른 묶음: `{info['group']}` (묶음 점수 {info['group_score']:.2f})."
        keys_out[key] = {**res, "note": note}
        for src, f in zip(res.get("sources", []), res["written"]):
            for part in src.split(" + "):
                used["w:" + part] = (used.get("w:" + part, "") + " " + f).strip()
        say(f"  {key}: {len(res['written'])}개 ({info.get('group', 'mix')}){' 바꿈 ' + str(len(res['fixes'])) if res['fixes'] else ''}")
    ctx["weapons"] = {"files": len(recs), "exts": dict(exts), "unreadable": sum(1 for r in recs if r.get("error")),
                      "classes": dict(classes.most_common(20)), "keys": keys_out}
    return recs


def stage_unnamed(recs: list[dict], cat: dict, dry: bool, top: int = 30) -> int:
    """File names say nothing: the most gunshot-like files go to the take-picking tool for rifle and
    pistol (not into the game), best first, to be chosen by ear."""
    want = ac.sound_cfg(cat, "rifle")["want"]
    scored = []
    for r in recs:
        if r["dur"] > 4.0:
            continue
        x, sr = decode(r["path"])
        a = ac.analyze(x, sr, want)
        scored.append({**r, "analysis": a, "score": float(a["score"])})
    scored.sort(key=lambda c: (-c["score"], c["rel"]))
    best = [c for c in scored if c["score"] >= 0.5][:top]
    if not dry:
        for key in ("rifle", "pistol"):
            staged = {stage_raw(key, c, dry).name: c for c in best}
            rank_path = ac.RAW / key / "ranking.json"
            rows = json.loads(rank_path.read_text(encoding="utf-8")) if rank_path.exists() else []
            rows = [r for r in rows if not str(r.get("file", "")).startswith("ron_")]
            rows += [{"file": name, "score": c["score"], "onset_s": c["analysis"].get("onset_s", 0.0), "events": c["analysis"].get("events", 0),
                      "centroid_hz": c["analysis"].get("centroid_hz", 0), "origin": c["rel"]} for name, c in staged.items()]
            rows.sort(key=lambda r: r.get("score", 0.0), reverse=True)
            rank_path.write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
    return len(best)


def godot_import(path: str) -> str:
    exe = Path(path)
    if not path or not exe.exists():
        return "Godot을 찾지 못해 건너뜀 (게임을 에디터로 한 번 열면 새 소리를 가져옵니다)"
    try:
        r = subprocess.run([str(exe), "--headless", "--path", str(ac.ROOT), "--import"], capture_output=True, timeout=900)
        return "완료" if r.returncode == 0 else f"오류 코드 {r.returncode}"
    except Exception as e:
        return f"실패: {e}"


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", nargs="?", default="apply", choices=["apply", "verify"])
    ap.add_argument("--voice-dir", default="")
    ap.add_argument("--weapons-dir", default="")
    ap.add_argument("--only", default="", help="voice, weapons or both (default)")
    ap.add_argument("--dry-run", action="store_true", help="report only, the game files stay as they are")
    ap.add_argument("--no-asr", action="store_true", help="no speech recognition")
    ap.add_argument("--asr-model", default="", help="whisper model, e.g. base.en (faster) or small.en (default)")
    ap.add_argument("--no-godot", action="store_true", help="do not run the Godot import afterwards")
    ap.add_argument("--fix", action="store_true", help="verify: move bad files to the backup folder")
    ap.add_argument("--config", default=str(CONFIG))
    args = ap.parse_args()
    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    cat = ac.load_catalog()
    backup = Backup(args.dry_run)
    if args.action == "verify":
        bad = verify_all(cat, args.fix, backup)
        for b in bad:
            say(f"{b['file']}: {', '.join(b['problems'])}" + ("  -> 치움" if b["removed"] else ""))
        say(f"검사: 문제 있는 파일 {len(bad)}개" + (f", 백업 {backup.dir}" if backup.saved else ""))
        return 1 if bad and not args.fix else 0
    ctx = {"time": datetime.now().strftime("%Y-%m-%d %H:%M"), "dry": args.dry_run, "warnings": []}
    only = {s.strip() for s in args.only.split(",") if s.strip()} or {"voice", "weapons"}
    used: dict[str, str] = {}
    voice, weapons = [], []
    ac.AUDIO.mkdir(parents=True, exist_ok=True)
    if "voice" in only:
        folder = Path(args.voice_dir or cfg["voice_dir"])
        ctx["voice_dir"] = str(folder)
        if folder.is_dir():
            voice = run_voice(cfg, folder, args, backup, ctx, used)
        else:
            ctx["warnings"].append(f"대사 폴더가 없습니다: {folder}")
            say(f"[대사] 폴더 없음: {folder}")
    if "weapons" in only:
        folder = Path(args.weapons_dir or cfg["weapons_dir"])
        ctx["weapons_dir"] = str(folder)
        if folder.is_dir():
            weapons = run_weapons(cfg, folder, args, cat, backup, ctx, used)
        else:
            ctx["warnings"].append(f"무기 폴더가 없습니다: {folder}")
            say(f"[무기] 폴더 없음: {folder}")
    if not args.dry_run:
        drop_orphan_imports()
        ctx["verify"] = verify_all(cat, True, backup)
        if ctx["verify"]:
            say(f"[검사] 문제 있는 게임 파일 {len(ctx['verify'])}개를 치웠습니다 (보고서 참고)")
        else:
            say("[검사] 모든 게임 소리 파일 정상")
        drop_orphan_imports()
        if not args.no_godot and (voice or weapons):
            say("[Godot] 새 소리 가져오는 중...")
            ctx["godot"] = godot_import(cfg.get("godot", ""))
            say(f"  {ctx['godot']}")
    if backup.saved:
        ctx["backup"], ctx["backup_n"] = backup.dir.name, len(backup.saved)
    write_inventory(voice, weapons, used)
    (WORK / "choices.json").write_text(json.dumps({k: v for k, v in ctx.items() if k != "time"}, indent=1, ensure_ascii=False, default=str), encoding="utf-8")
    report = write_report(ctx)
    for w in ctx["warnings"]:
        say(f"주의: {w}")
    say(f"보고서: {report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
