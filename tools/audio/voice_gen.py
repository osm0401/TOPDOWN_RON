"""Korean command lines with Chatterbox (local AI voice). Needs the Chatterbox environment:

  D:\\tools\\cbox\\Scripts\\python tools\\audio\\voice_gen.py --test                       # 4 lines x 3 emotion settings
  D:\\tools\\cbox\\Scripts\\python tools\\audio\\voice_gen.py --lines down:1 --settings 1.5:0.2,2.0:0.0 --shift=-5,-7
  D:\\tools\\cbox\\Scripts\\python tools\\audio\\voice_gen.py --make-ref default_p-7 --name deep_boot
  D:\\tools\\cbox\\Scripts\\python tools\\audio\\voice_gen.py --all --takes 8 --dry-run

Output: assets/audio/_voice_gen/<set>/<name>.wav, one file per take (the name carries the settings).
  --settings e:c,...   emotion (exaggeration, 0.25-2) and cfg_weight (0-1); more emotion, less cfg = harder, faster delivery
  --shift n,...        also write copies pitched n semitones (negative = deeper) into the set <voice>_p<n>
  --make-ref SET       join the takes of a set into one 6-10 s clip assets/audio/_voice_ref/<name>.wav; used as a
                       reference voice by later runs (every clip in _voice_ref gives its own set of takes)
Reference voices: short recordings (5-10 s) of your own or a consenting person's voice, shouting like the
line should sound. The reference decides the timbre and much of the style.
"""
import argparse
import json
import os
import random
from pathlib import Path

os.environ.setdefault("HF_HOME", "D:/tools/cbox_hf")  # model files stay on the D drive
os.environ.setdefault("TORCH_HOME", "D:/tools/cache/torch")
os.environ.setdefault("XDG_CACHE_HOME", "D:/tools/cache/xdg")

ROOT = Path(__file__).resolve().parents[2]
COMMANDS = ROOT / "data" / "commands.json"
GEN = ROOT / "assets" / "audio" / "_voice_gen"
REF = ROOT / "assets" / "audio" / "_voice_ref"

TEST_LINES = [("weapon_drop", 0), ("down", 1), ("freeze", 0), ("turn", 0)]
TEST_SETTINGS = [(0.5, 0.5), (0.8, 0.3), (1.2, 0.3)]  # (exaggeration, cfg_weight)


def command_lines() -> dict[str, list[str]]:
    d = json.loads(COMMANDS.read_text(encoding="utf-8"))
    return {k: v for k, v in d.items() if isinstance(v, list)}


def parse_lines(text: str) -> list[tuple[str, int]]:
    """'down:1,freeze:0' -> [('down', 1), ('freeze', 0)]"""
    return [(k, int(i)) for k, i in (p.split(":") for p in text.split(",") if p)]


def parse_settings(text: str) -> list[tuple[float, float]]:
    """'1.5:0.2,2.0:0.0' -> [(1.5, 0.2), (2.0, 0.0)]"""
    return [(float(e), float(c)) for e, c in (p.split(":") for p in text.split(",") if p)]


def set_name(voice: Path | None, shift: int) -> str:
    return (voice.stem if voice else "default") + (f"_p{shift}" if shift else "")


def plan(lines: dict, picks: list[tuple[str, int]], settings: list[tuple[float, float]], takes: int, refs: list[Path],
         with_default: bool, shifts: list[int]) -> list[dict]:
    """One job per take: the line, the emotion settings, the reference voice (None = default voice), the seed."""
    voices: list[Path | None] = ([None] if with_default else []) + list(refs)
    jobs = []
    for key, i in picks:
        for voice in voices:
            for e, c in settings:
                for t in range(takes):
                    jobs.append({"voice": voice, "name": f"voice_{key}_{i}__ex{e}_cfg{c}_t{t}", "text": lines[key][i],
                                 "exaggeration": e, "cfg_weight": c, "seed": 1000 * (i + 1) + t, "shifts": shifts})
    return jobs


def run(jobs: list[dict]) -> None:
    import librosa
    import soundfile as sf
    import torch
    from chatterbox.mtl_tts import ChatterboxMultilingualTTS

    print("[*] loading the model (the first run downloads it to", os.environ["HF_HOME"], ")", flush=True)
    model = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
    for n, j in enumerate(jobs, 1):
        base = GEN / set_name(j["voice"], 0) / (j["name"] + ".wav")
        if not base.exists():
            base.parent.mkdir(parents=True, exist_ok=True)
            random.seed(j["seed"])
            torch.manual_seed(j["seed"])
            kw = {"audio_prompt_path": str(j["voice"])} if j["voice"] else {}
            wav = model.generate(j["text"], language_id="ko", exaggeration=j["exaggeration"], cfg_weight=j["cfg_weight"], **kw)
            sf.write(base, wav.squeeze(0).cpu().numpy(), model.sr)
            print(f"[+] {n}/{len(jobs)} {base.parent.name}/{j['name']}  \"{j['text']}\"", flush=True)
        for s in j["shifts"]:
            out = GEN / set_name(j["voice"], s) / (j["name"] + ".wav")
            if not out.exists():
                out.parent.mkdir(parents=True, exist_ok=True)
                y, sr = sf.read(base, dtype="float32")
                sf.write(out, librosa.effects.pitch_shift(y, sr=sr, n_steps=s), sr)


def make_ref(set_dir: str, name: str, max_s: float = 10.0) -> Path:
    """Join takes of a set (sorted by name) into one clip, 0.25 s apart, up to max_s seconds."""
    import numpy as np
    import soundfile as sf

    pieces, total, sr = [], 0.0, 24000
    for p in sorted((GEN / set_dir).glob("*.wav")):
        y, sr = sf.read(p, dtype="float32")
        if len(y) / sr > 4.0:  # skip runaway takes
            continue
        pieces += [y, np.zeros(int(0.25 * sr), dtype=np.float32)]
        total += len(y) / sr + 0.25
        if total >= max_s:
            break
    REF.mkdir(parents=True, exist_ok=True)
    out = REF / f"{name}.wav"
    sf.write(out, np.concatenate(pieces), sr)
    print(f"reference {out.name}: {total:.1f} s from {len(pieces) // 2} take(s)")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", action="store_true", help="4 lines x 3 emotion settings")
    ap.add_argument("--all", action="store_true", help="every command line")
    ap.add_argument("--lines", default="", help="e.g. down:1,freeze:0")
    ap.add_argument("--settings", default="", help="exaggeration:cfg pairs, e.g. 1.5:0.2,2.0:0.0")
    ap.add_argument("--shift", default="", help="pitch shifts in semitones, e.g. -5,-7")
    ap.add_argument("--takes", type=int, default=1, help="takes per line and setting")
    ap.add_argument("--no-default", action="store_true", help="only reference voices, not the default voice")
    ap.add_argument("--ref", default="", help="only this reference clip (file name without .wav)")
    ap.add_argument("--make-ref", default="", help="join the takes of this set into a reference clip")
    ap.add_argument("--name", default="boot", help="name of the reference clip for --make-ref")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.make_ref:
        make_ref(a.make_ref, a.name)
        return
    lines = command_lines()
    refs = sorted(REF.glob("*.wav")) if REF.is_dir() else []
    if a.ref:
        refs = [r for r in refs if r.stem == a.ref]
    if a.all:
        picks = [(k, i) for k, v in lines.items() for i in range(len(v))]
        settings = [(0.8, 0.3), (1.0, 0.3)]
    elif a.test:
        picks, settings = TEST_LINES, TEST_SETTINGS
    elif a.lines:
        picks, settings = parse_lines(a.lines), TEST_SETTINGS
    else:
        raise SystemExit(__doc__)
    if a.lines:
        picks = parse_lines(a.lines)
    if a.settings:
        settings = parse_settings(a.settings)
    shifts = [int(s) for s in a.shift.split(",") if s]
    jobs = plan(lines, picks, settings, a.takes, refs, not a.no_default, shifts)
    print(f"{len(jobs)} take(s); voices: {'default' if not a.no_default else ''} {' '.join(r.stem for r in refs)}; shifts {shifts}")
    if not a.dry_run:
        run(jobs)


if __name__ == "__main__":
    main()
