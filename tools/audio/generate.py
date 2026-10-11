"""Generate raw takes with Stable Audio Open (needs `hf auth login` once and the model access).

  python tools/audio/generate.py --dry-run              # what would run, with a time estimate
  python tools/audio/generate.py --probe                # 2 takes of every sound: check the prompts first
  python tools/audio/generate.py --only rifle,pistol    # the full set of takes for some sounds
  python tools/audio/generate.py                        # everything in the catalog

Run it with the generator environment:  D:\\tools\\sao\\Scripts\\python tools\\audio\\generate.py
Takes go to assets/audio/_raw/<key>/<key>_s<seed>.wav and each one is logged in manifest.jsonl.
Existing seeds are skipped, so an interrupted run can simply be started again.
The GPU temperature is checked before every batch (--max-temp); --rest adds a pause between batches.
"""
import argparse
import gc
import json
import os
import subprocess
import time
from datetime import datetime

os.environ.setdefault("HF_HOME", "D:/tools/sao/hf_cache")  # login + model files live on the D drive

from audio_common import RAW, load_catalog, sound_cfg, write_wav  # noqa: E402

SECONDS_PER_TAKE = 28.0  # measured on an RTX 3060 at 100 steps: the cost per take does not depend on its length


def done_seeds(key: str) -> set[int]:
    out = set()
    for p in (RAW / key).glob(f"{key}_s*.wav"):
        try:
            out.add(int(p.stem.rsplit("_s", 1)[1]))
        except ValueError:
            pass
    return out


def plan(cat: dict, only: list[str], takes: int, probe: bool, seed_base: int) -> list[dict]:
    """Per sound: the seeds still to generate (existing takes are skipped)."""
    work = []
    for key in cat["sounds"]:
        if only and key not in only:
            continue
        cfg = sound_cfg(cat, key)
        n = 2 if probe else (takes or int(cfg["takes"]))
        seeds = [s for s in range(seed_base, seed_base + n) if s not in done_seeds(key)]
        if seeds:
            work.append({"key": key, "cfg": cfg, "seeds": seeds})
    return work


def estimate_minutes(work: list[dict]) -> float:
    secs = sum(len(w["seeds"]) * int(w["cfg"]["steps"]) / 100.0 * SECONDS_PER_TAKE for w in work)
    return secs / 60.0


def gpu_temp() -> int | None:
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout.strip().splitlines()
        return int(out[0])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def wait_cool(max_temp: int) -> None:
    while True:
        t = gpu_temp()
        if t is None or t <= max_temp:
            return
        print(f"[!] GPU {t} C is above {max_temp} C: waiting 20 s", flush=True)
        time.sleep(20)


def run(cat: dict, work: list[dict], max_temp: int, rest: float) -> None:
    import torch
    from diffusers import StableAudioPipeline

    print("[*] loading the model", flush=True)
    pipe = StableAudioPipeline.from_pretrained(cat["model"], torch_dtype=torch.float16).to("cuda")
    sr = pipe.vae.sampling_rate
    for w in work:
        key, cfg, seeds = w["key"], w["cfg"], w["seeds"]
        batch = int(cfg["batch"])
        for i in range(0, len(seeds), batch):
            chunk = seeds[i:i + batch]
            wait_cool(max_temp)
            t0 = time.time()
            kw = dict(negative_prompt=cfg["negative"], num_inference_steps=int(cfg["steps"]), audio_end_in_s=float(cfg["seconds"]))
            try:
                audios = pipe(cfg["prompt"], num_waveforms_per_prompt=len(chunk),
                              generator=[torch.Generator("cuda").manual_seed(s) for s in chunk], **kw).audios
            except (ValueError, TypeError):  # this pipeline version takes a single generator only
                audios = []
                for s in chunk:
                    audios += list(pipe(cfg["prompt"], num_waveforms_per_prompt=1, generator=torch.Generator("cuda").manual_seed(s), **kw).audios)
            (RAW / key).mkdir(parents=True, exist_ok=True)
            with open(RAW / key / "manifest.jsonl", "a", encoding="utf-8") as log:
                for s, a in zip(chunk, audios):
                    name = f"{key}_s{s}.wav"
                    write_wav(RAW / key / name, a.T.float().cpu().numpy(), sr)
                    log.write(json.dumps({"file": name, "key": key, "seed": s, "prompt": cfg["prompt"], "negative": cfg["negative"],
                                          "steps": int(cfg["steps"]), "seconds": float(cfg["seconds"]), "model": cat["model"],
                                          "time": datetime.now().isoformat(timespec="seconds")}, ensure_ascii=False) + "\n")
            print(f"[+] {key}: seeds {chunk[0]}..{chunk[-1]} in {time.time() - t0:.0f} s (GPU {gpu_temp()} C)", flush=True)
            del audios
            gc.collect()
            torch.cuda.empty_cache()  # give cached blocks back: a 12 GB card that overflows into system memory runs 3x slower
            time.sleep(rest)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma separated sound keys")
    ap.add_argument("--takes", type=int, default=0, help="takes per sound (default: the catalog value)")
    ap.add_argument("--probe", action="store_true", help="2 takes per sound, to check the prompts")
    ap.add_argument("--seed-base", type=int, default=1)
    ap.add_argument("--max-temp", type=int, default=80, help="pause while the GPU is hotter than this (C)")
    ap.add_argument("--rest", type=float, default=5.0, help="seconds to rest between batches")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    cat = load_catalog()
    work = plan(cat, [k for k in a.only.split(",") if k], a.takes, a.probe, a.seed_base)
    total = sum(len(w["seeds"]) for w in work)
    for w in work:
        print(f"{w['key']:<11} {len(w['seeds']):>3} takes x {w['cfg']['seconds']} s")
    print(f"total {total} takes, about {estimate_minutes(work):.0f} minutes")
    if not a.dry_run and work:
        run(cat, work, a.max_temp, a.rest)


if __name__ == "__main__":
    main()
