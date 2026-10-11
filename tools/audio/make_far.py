"""Make the "heard from far away" version of a sound by processing the close one (no AI needed).

  python tools/audio/make_far.py --src rifle --dst rifle_far            # writes assets/audio/_far_dsp/ to compare
  python tools/audio/make_far.py --src rifle --dst rifle_far --apply    # writes the game files rifle_far_<n>.wav

Reads the game files <src>_<n>.wav, so run process.py first. The sound goes duller (--cutoff), keeps
its low thump (--boom), loses the sharp attack (--soften) and gets a long echo tail (--wet, --decay).
Without --apply nothing in the game changes: listen to the result first. --apply replaces every
<dst>_<n>.wav, including far sounds that came from the AI.
"""
import argparse
import re

from audio_common import AUDIO, far_version, fade_out, highpass, normalize_peak, read_mono, write_wav

OUT = AUDIO / "_far_dsp"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="close sound key, e.g. rifle")
    ap.add_argument("--dst", required=True, help="far sound key, e.g. rifle_far")
    ap.add_argument("--cutoff", type=float, default=1800.0, help="low-pass in Hz: lower = more distant")
    ap.add_argument("--boom", type=float, default=0.35, help="how much low thump to keep")
    ap.add_argument("--wet", type=float, default=0.8, help="echo tail level")
    ap.add_argument("--decay", type=float, default=1.8, help="echo tail length in seconds")
    ap.add_argument("--soften", type=float, default=4.0, help="attack rounding in ms")
    ap.add_argument("--apply", action="store_true", help="write the game files instead of the comparison folder")
    a = ap.parse_args()
    files = sorted(p for p in AUDIO.glob(f"{a.src}_*.wav") if re.fullmatch(rf"{re.escape(a.src)}_\d+\.wav", p.name))
    if not files:
        raise SystemExit(f"no game files {a.src}_<n>.wav in {AUDIO}: run process.py first")
    out_dir = AUDIO if a.apply else OUT
    if a.apply:
        for p in AUDIO.glob(f"{a.dst}_*.wav"):
            if re.fullmatch(rf"{re.escape(a.dst)}_\d+\.wav", p.name):
                p.unlink()
    for n, src in enumerate(files):
        x, sr = read_mono(src)
        y = far_version(x, sr, a.cutoff, a.boom, a.wet, a.decay, a.soften)
        y = fade_out(highpass(y, sr, 40.0), sr, 0.4)
        write_wav(out_dir / f"{a.dst}_{n}.wav", normalize_peak(y, 0.95), sr)
    print(f"{len(files)} far file(s) -> {out_dir}")


if __name__ == "__main__":
    main()
