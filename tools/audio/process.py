"""Turn picked takes into game files assets/audio/<key>_<n>.wav: mono, trimmed to the sound, low rumble
filtered out, faded, peak-normalized (looped seamlessly for room tone).

  python tools/audio/process.py --from-shortlist --replace        # every shortlisted take
  python tools/audio/process.py --only rifle --replace            # your picks in assets/audio/_pick/rifle/
  python tools/audio/process.py --file D:/x/take.wav --key rifle  # one arbitrary file

--replace deletes the existing <key>_<n>.wav files of that sound first (without it the tool stops
if some exist). assets/audio/manifest.json records, per game file, where it came from (seed,
prompt, model) so a sound can always be traced and regenerated.
"""
import argparse
import json
import re
from pathlib import Path

import numpy as np

from audio_common import (AUDIO, PICK, RAW, SHORTLIST, fade_out, highpass, load_catalog, make_loop, normalize_peak,
                          read_mono, sound_cfg, trim_lead, trim_tail, write_wav)

MANIFEST = AUDIO / "manifest.json"


def process_one(x: np.ndarray, sr: int, cfg: dict) -> np.ndarray:
    """One raw take -> game sound. Room tone keeps its start; everything else starts at the sound."""
    if not cfg.get("loop"):
        x = trim_lead(x, sr)
    if "tail_s" in cfg:  # room tone loops over its whole length: nothing to cut
        x = trim_tail(x, sr, float(cfg["tail_s"]))
    x = highpass(x, sr, float(cfg["lowcut_hz"]))
    if cfg.get("loop"):
        x = make_loop(x, sr, float(cfg["crossfade_s"]))
    else:
        x = fade_out(x, sr, float(cfg["fade_s"]))
    return normalize_peak(x, float(cfg["peak"]))


def source_info(key: str, path: Path) -> dict:
    """Seed and prompt of a raw take from its manifest, when the file name says which one it is."""
    m = re.search(r"_s(\d+)\.wav$", path.name)
    log = RAW / key / "manifest.jsonl"
    if m and log.exists():
        for line in log.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            if row["seed"] == int(m.group(1)):
                return {"seed": row["seed"], "prompt": row["prompt"], "model": row["model"], "steps": row["steps"]}
    return {}


def numbered(key: str) -> list[Path]:
    return sorted(p for p in AUDIO.glob(f"{key}_*.wav") if re.fullmatch(rf"{re.escape(key)}_\d+\.wav", p.name))


def process_key(key: str, cfg: dict, files: list[Path], replace: bool) -> list[Path]:
    old = numbered(key)
    if old and not replace:
        raise SystemExit(f"{key}: {len(old)} game file(s) already exist; add --replace to overwrite them")
    for p in old:
        p.unlink()
    entries, outs = [], []
    for n, src in enumerate(files):
        x, sr = read_mono(src)
        out = AUDIO / f"{key}_{n}.wav"
        write_wav(out, process_one(x, sr, cfg), sr)
        outs.append(out)
        entries.append({"file": out.name, "source": src.name, **source_info(key, src)})
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else {}
    manifest[key] = entries
    MANIFEST.write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    return outs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma separated sound keys")
    ap.add_argument("--from-shortlist", action="store_true", help="use the shortlist instead of assets/audio/_pick")
    ap.add_argument("--file", default="", help="process this one file (needs --key)")
    ap.add_argument("--key", default="")
    ap.add_argument("--replace", action="store_true")
    a = ap.parse_args()
    cat = load_catalog()
    if a.file:
        jobs = {a.key: [Path(a.file)]}
    else:
        only = [k for k in a.only.split(",") if k]
        base = SHORTLIST if a.from_shortlist else PICK
        jobs = {k: sorted((base / k).glob("*.wav")) for k in cat["sounds"] if (not only or k in only) and (base / k).is_dir()}
    for key, files in jobs.items():
        if not files:
            continue
        outs = process_key(key, sound_cfg(cat, key), files, a.replace)
        print(f"{key}: {len(outs)} game file(s): {', '.join(p.name for p in outs)}")


if __name__ == "__main__":
    main()
