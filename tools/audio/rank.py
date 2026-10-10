"""Score every raw take against the rules of its kind and copy the best ones to the shortlist.

  python tools/audio/rank.py                      # all sounds that have raw takes
  python tools/audio/rank.py --only rifle,pistol --top 8

Reads assets/audio/_raw/<key>/*.wav, writes _raw/<key>/ranking.json and copies the top takes to
assets/audio/_shortlist/<key>/<rank>_<score>_<file>.wav. Listen to the shortlist (or the F7
audition panel after processing), copy your favourites into assets/audio/_pick/<key>/ and run
process.py. The score only filters obvious failures (several bangs, late start, clipping,
wrong timbre): the final choice is yours.
"""
import argparse
import json
import shutil

from audio_common import RAW, SHORTLIST, analyze, load_catalog, read_mono, sound_cfg


def rank_key(key: str, cfg: dict) -> list[dict]:
    rows = []
    for path in sorted((RAW / key).glob(f"{key}_s*.wav")):
        x, sr = read_mono(path)
        rows.append({"file": path.name, **analyze(x, sr, cfg["want"])})
    rows.sort(key=lambda r: r["score"], reverse=True)
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma separated sound keys")
    ap.add_argument("--top", type=int, default=0, help="takes to keep per sound (default: the catalog 'keep')")
    a = ap.parse_args()
    cat = load_catalog()
    only = [k for k in a.only.split(",") if k]
    for key in cat["sounds"]:
        if (only and key not in only) or not (RAW / key).is_dir():
            continue
        cfg = sound_cfg(cat, key)
        rows = rank_key(key, cfg)
        if not rows:
            continue
        keep = a.top or int(cfg["keep"])
        (RAW / key / "ranking.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
        out = SHORTLIST / key
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        print(f"== {key}: {len(rows)} takes, keeping {min(keep, len(rows))}")
        for i, r in enumerate(rows[:keep]):
            shutil.copy(RAW / key / r["file"], out / f"{i + 1:02d}_{int(r['score'] * 100):03d}_{r['file']}")
            print(f"  {i + 1:>2}. {r['score']:.2f}  {r['file']}  onset {r.get('onset_s')} s  events {r.get('events')}  centroid {r.get('centroid_hz')} Hz")
        bad = [r for r in rows if r["score"] < 0.5]
        if bad:
            print(f"  ({len(bad)} take(s) scored below 0.5)")


if __name__ == "__main__":
    main()
