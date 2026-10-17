"""Self-check of the Ready or Not import (import_ron.py) on made-up export folders: synthetic "voices"
(each line its own pitch, so a stand-in for speech recognition can tell them apart even after
trimming) and synthetic gunshots. Needs numpy, scipy and soundfile only; nothing in assets/audio
is touched (everything runs in a temporary folder).

  D:\\tools\\sao\\Scripts\\python tools\\audio\\test_import_ron.py
"""
import hashlib
import json
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

import audio_common as ac
import import_ron as ir
import process
import ron_match as rm

SR = 48000
failed = 0


def check(cond: bool, label: str) -> None:
    global failed
    print(("PASS " if cond else "FAIL ") + label)
    failed += 0 if cond else 1


# ---- matching rules ---------------------------------------------------------------

check(rm.similarity("Hands up, now.", "Hands up now!") == 1.0, "punctuation and case do not matter")
check(rm.similarity("Don't move!", "Do not move") == 1.0, "contractions are spelled out")
check(rm.similarity("Hands up now!", "Hands up now!") > rm.similarity("Hands up now!", "Hands up!") >= 0.75,
      "a line with an extra word is close but the exact line wins")
check(rm.similarity("Drop it!", "Stop it!") < 0.75, "different words do not match")
check(rm.similarity("[grunts]", "Hands up!") == 0.0 and rm.noise_marks("[grunts] (groans)") == ["grunts", "groans"], "sound descriptions are not words")
check(rm.split_number("HandsUp_03") == ("HandsUp", 3) and rm.split_number("Yell (2)") == ("Yell", 2), "take numbers are read")
check(rm.split_number("M4A1") == ("M4A1", None) and rm.split_number("Shot01") == ("Shot", 1), "a digit glued to a name is not a take number")
check({"m4a1", "shot", "close"} <= rm.name_tokens("M4A1_ShotClose_01"), "file names split into words")
toks = rm.name_tokens("SWAT_Eli_DontMove_01")
check(rm.phrase_in_name("Don't move!", toks, "swatelidontmove01"), "a line spelled out in a file name is found")
check(not rm.phrase_in_name("Drop it!", rm.name_tokens("Weapon_Drop_Mag"), "weapondropmag"), "one shared word is not enough")

names = [f"VO/Eli_Yell_HandsUp_{n:02d}.wav" for n in range(1, 18)] + [f"VO/Eli_Misc_{n}.wav" for n in range(40)]
mapping, info = rm.table_group(names, list(range(17)), ["handsup"])
check(info.get("base") == 1 and mapping[0].endswith("HandsUp_01.wav") and mapping[16].endswith("HandsUp_17.wav"),
      "the line table finds its numbered group (counting from 1)")

wcfg = json.loads(ir.CONFIG.read_text(encoding="utf-8"))["weapons"]
wi = {n: rm.weapon_info(n, wcfg) for n in ["ARN180_Shot_Close_01.wav", "ARN180ShotFar03.wav", "G19_Fire_Close_02.wav",
                                           "MP5_Shot_Suppressed_01.wav", "ARN180_Tail_Int_01.wav", "ARN180_MagOut_01.wav",
                                           "ARN180_MagIn_01.wav", "Impact_Flesh_02.wav", "Taser_Fire_01.wav"]}
check(wi["ARN180_Shot_Close_01.wav"]["class"] == "rifle" and wi["ARN180_Shot_Close_01.wav"]["layer"] == "shot", "a rifle shot is classified")
check(wi["ARN180ShotFar03.wav"]["layer"] == "far" and wi["ARN180ShotFar03.wav"]["weapon"] == wi["ARN180_Shot_Close_01.wav"]["weapon"],
      "far and close takes of one gun share the weapon id (camelCase too)")
check(wi["G19_Fire_Close_02.wav"]["class"] == "pistol", "a pistol shot is classified")
check(wi["MP5_Shot_Suppressed_01.wav"]["excluded"] == ["suppressed"], "suppressed shots are left out")
check([wi[n]["layer"] for n in ["ARN180_Tail_Int_01.wav", "ARN180_MagOut_01.wav", "ARN180_MagIn_01.wav", "Impact_Flesh_02.wav", "Taser_Fire_01.wav"]]
      == ["tail", "mag_out", "mag_in", "flesh_impact", "taser"], "layers: tail, magazine out / in, body impact, taser")

slots = rm.distribute([["a", "b"], [], ["c"], []], ["a", "b", "c", "d"], 4)
check(all(len(s) == len(set(s)) == 4 for s in slots) and slots[0][:2] == ["a", "b"] and slots[2][0] == "c", "every sentence gets 4 different takes, own lines first")
check(set(sum(slots, [])) == {"a", "b", "c", "d"}, "every found line plays somewhere")

# ---- the configuration fits the game --------------------------------------------------

cfg = json.loads(ir.CONFIG.read_text(encoding="utf-8"))
game_lines = json.loads(ir.COMMANDS.read_text(encoding="utf-8"))
ns = sorted(n for c in cfg["commands"].values() for s in c for n in s["table"])
check(ns == sorted(n for e in cfg["table"] for n in e["n"]), "every line of the table goes to exactly one sentence")
check(set(cfg["commands"]) == {k for k, v in game_lines.items() if isinstance(v, list)}
      and all([s["ko"] for s in cfg["commands"][k]] == game_lines[k] for k in cfg["commands"]), "the sentences follow data/commands.json")
phrases = [" ".join(rm.words(p)) for c in cfg["commands"].values() for s in c for p in s["phrases"]] + [" ".join(rm.words(e["text"])) for e in cfg["table"]]
check(len(phrases) == len(set(phrases)), "no phrase is listed for two sentences")
check(all(k in ac.load_catalog()["sounds"] for k in cfg["weapons"]["keys"]), "every weapon key is a game sound")

# ---- quality measures ------------------------------------------------------------------


def voice(f0: float, seconds: float = 1.2, seed: int = 0, syll: int = 3) -> np.ndarray:
    """A voice-like line: harmonics of f0 in syllable bursts, a little breath noise up high."""
    t = np.arange(int(seconds * SR)) / SR
    tone = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, 12))
    env = np.clip(np.sin(np.pi * syll * t / seconds), 0, None) ** 0.7
    hiss = signal.sosfilt(signal.butter(2, 5000, "highpass", fs=SR, output="sos"), np.random.default_rng(seed).normal(0, 0.05, len(t)))
    x = (tone / 3 + hiss) * env
    pad = np.zeros(int(0.08 * SR))
    return (np.concatenate([pad, x, pad]) * 0.8 / np.abs(x).max()).astype(np.float32)


clean = voice(140)
q_clean = ac.voice_quality(ac.voice_metrics(clean, SR), SR)[0]
radio = signal.sosfilt(signal.butter(6, [300, 3000], "bandpass", fs=SR, output="sos"), clean).astype(np.float32)
q_radio, why_radio = ac.voice_quality(ac.voice_metrics(radio, SR), SR)
noise = np.random.default_rng(1).uniform(-0.3, 0.3, SR).astype(np.float32)
check(q_clean == 1.0, "a clean line scores 1")
check(q_radio < ir.POOR and any("radio" in w for w in why_radio), "a radio voice is marked poor")
check(ac.voice_quality(ac.voice_metrics(noise, SR), SR)[0] == 0.0, "steady noise is not a line")
check(ac.voice_quality(ac.voice_metrics(np.zeros(SR, np.float32), SR), SR)[0] == 0.0, "silence is not a line")
check(ac.audio_problems(np.zeros(0, np.float32), SR, 0.1, 5) == ["empty"], "an empty file is caught")
check("clipped" in ac.audio_problems(np.clip(clean * 8, -1, 1), SR, 0.1, 5), "a clipped file is caught")
check(ac.audio_problems(ir.voice_take(clean, SR), SR, 0.25, 6) == [], "a processed line passes the game check")

# ---- the whole import on made-up folders -------------------------------------------------

TABLE = {n: e["text"] for e in cfg["table"] for n in e["n"]}
EXTRA = {"Eli_DropWeapon_01": "Drop the weapon!", "Eli_GetDown_01": "Get down!", "Eli_Freeze_01": "Freeze!",
         "Eli_TurnAround_01": "Turn around!", "Eli_RoomClear_01": "Room clear!", "Eli_Pain_01": "", "Eli_Pain_02": ""}
PITCH: dict[float, str] = {}


def bang(total: float, tau: float, hz: float, seed: int, at: float = 0.01) -> np.ndarray:
    x = np.zeros(int(total * SR), np.float32)
    i = int(at * SR)
    n = min(int(0.6 * SR), len(x) - i)
    burst = signal.sosfilt(signal.butter(2, hz, "lowpass", fs=SR, output="sos"), np.random.default_rng(seed).uniform(-1, 1, n))
    x[i:i + n] = burst * np.exp(-np.arange(n) / SR / tau)
    return (x / np.abs(x).max() * 0.9).astype(np.float32)


def click(seed: int) -> np.ndarray:
    return bang(0.4, 0.004, 9000, seed) * 0.6


def make_folders(root: Path) -> tuple[Path, Path]:
    vo, wp = root / "SWATEli", root / "Weapons[0]"
    vo.mkdir(parents=True)
    wp.mkdir(parents=True)
    f0 = 110.0
    for n, text in TABLE.items():
        x = np.zeros(SR, np.float32) if n == 7 else voice(f0, 0.8 + 0.05 * n, seed=n)
        PITCH[f0] = text if n != 7 else ""
        sf.write(str(vo / f"Eli_Yell_HandsUp_{n:02d}.wav"), x, SR)
        f0 += 7.0
    for k, (name, text) in enumerate(EXTRA.items()):
        x = voice(f0, 0.35 if "Pain" in name else 1.0, seed=50 + k, syll=1 if "Pain" in name else 3)
        PITCH[f0] = text
        sf.write(str(vo / f"{name}.wav"), x, SR)
        f0 += 7.0
    rad = signal.sosfilt(signal.butter(6, [300, 3000], "bandpass", fs=SR, output="sos"), voice(f0, 1.0)).astype(np.float32)
    PITCH[f0] = "Hands up!"
    sf.write(str(vo / "Eli_Radio_HandsUp_01.wav"), rad, SR)
    sf.write(str(vo / "Eli_Hiss_01.wav"), noise, SR)
    (vo / "Eli_Broken_01.wav").write_bytes(b"")
    for k in range(1, 5):
        sf.write(str(wp / f"ARN180_Shot_Close_{k:02d}.wav"), bang(1.5, 0.03, 3000, k), SR)
    sf.write(str(wp / "ARN180_Shot_Close_05.wav"), bang(1.5, 0.03, 3000, 5) + bang(1.5, 0.03, 3000, 6, at=0.6), SR)  # two bangs
    sf.write(str(wp / "SA58_Shot_Close_01.wav"), bang(1.5, 0.03, 2500, 9), SR)
    sf.write(str(wp / "ARN180_Shot_Close_Suppressed_01.wav"), bang(1.0, 0.02, 1500, 10), SR)
    for k in range(1, 4):
        sf.write(str(wp / f"G19_Fire_Close_{k:02d}.wav"), bang(1.2, 0.02, 3500, 20 + k), SR)
    sf.write(str(wp / "ARN180_MagOut_01.wav"), click(30), SR)
    sf.write(str(wp / "ARN180_MagIn_01.wav"), click(31), SR)
    sf.write(str(wp / "ARN180_BoltRelease_01.wav"), click(32), SR)
    sf.write(str(wp / "Weapons_Empty_01.wav"), np.zeros(SR, np.float32), SR)
    return vo, wp


def fake_asr(x16: np.ndarray):
    """Stand-in for whisper: names the line by its pitch (which trimming and levelling keep)."""
    if len(x16) < 1600 or np.abs(x16).max() < 0.003:
        return "", 0.0, 0.99
    spec = np.abs(np.fft.rfft(x16 * np.hanning(len(x16))))
    freqs = np.fft.rfftfreq(len(x16), 1 / 16000)
    band = (freqs > 90) & (freqs < 400)
    f = float(freqs[band][np.argmax(spec[band])])
    near = min(PITCH, key=lambda p: abs(p - f))
    return (PITCH[near] if abs(near - f) < 2.5 else ""), 0.9, 0.01


def snapshot(folder: Path) -> str:
    h = hashlib.md5()
    for p in sorted(folder.rglob("*")):
        if p.is_file() and "_import" not in p.parts:
            h.update(p.name.encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def run(args: list[str]) -> int:
    sys.argv = ["import_ron.py"] + args
    return ir.main()


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    vo, wp = make_folders(tmp / "export")
    audio = tmp / "audio"
    audio.mkdir()
    # point every tool at the temporary game folder
    ac.AUDIO, ac.RAW, ac.PICK = audio, audio / "_raw", audio / "_pick"
    process.AUDIO, process.RAW, process.MANIFEST = audio, audio / "_raw", audio / "manifest.json"
    ir.WORK, ir.BACKUP = audio / "_import", audio / "_backup"
    ir.load_asr = lambda model: (fake_asr, "stand-in (test)")
    sf.write(str(audio / "voice_down_0_0.wav"), clean, SR)  # an old recording: must end up in the backup
    sf.write(str(audio / "door_0.wav"), np.zeros(SR, np.float32), SR)  # an empty old file: the final check removes it
    (audio / "rifle_9.wav.import").write_text("stale")

    before = snapshot(audio)
    run(["--dry-run", "--no-godot", "--voice-dir", str(vo), "--weapons-dir", str(wp)])
    check(snapshot(audio) == before and not ir.BACKUP.exists(), "a dry run changes no game file")

    run(["--no-godot", "--voice-dir", str(vo), "--weapons-dir", str(wp)])
    ctx = json.loads((ir.WORK / "choices.json").read_text(encoding="utf-8"))
    report = (ir.WORK / "REPORT.md").read_text(encoding="utf-8")
    voices = sorted(p.name for p in audio.glob("voice_*.wav"))
    lines = {cmd: len({t["source"] for s in c for t in s["takes"]}) for cmd, c in ctx["voice"]["commands"].items()}
    check(lines == {"weapon_drop": 5, "down": 3, "freeze": 6, "turn": 6}, f"lines found per command {lines}")
    check(len(voices) == sum(4 * min(4, n) for n in lines.values()) == 60,
          f"every sentence has 4 different takes, or as many as its command has lines (down: 3), got {len(voices)}")
    srcs = {t["source"] for c in ctx["voice"]["commands"].values() for s in c for t in s["takes"]}
    want = {f"Eli_Yell_HandsUp_{n:02d}.wav" for n in TABLE if n != 7} | {f"{k}.wav" for k in EXTRA if "Pain" not in k and "Room" not in k}
    check(want <= srcs, "every table line and every same-meaning line is used")
    check(not srcs & {"Eli_Yell_HandsUp_07.wav", "Eli_Radio_HandsUp_01.wav", "Eli_Hiss_01.wav", "Eli_RoomClear_01.wav", "Eli_Broken_01.wav"},
          "the silent take, the radio voice, noise, unrelated and broken files stay out")
    drop = [t["line"] for s in ctx["voice"]["commands"]["weapon_drop"] for t in s["takes"]]
    check("Drop the weapon!" in drop and "Police! Hands up!" in drop, "weapon_drop has its table lines and \"Drop the weapon!\"")
    row7 = next(r for r in ctx["voice"]["table_rows"] if r["n"] == 7)
    check("Eli_Yell_HandsUp_06" in row7["file"] and "07" in row7["used"], "the empty table take is reported and its twin line used")
    for p in audio.glob("voice_*.wav"):
        x, sr = ac.read_mono(p)
        if ac.audio_problems(x, sr, 0.25, 6.0):
            check(False, f"{p.name} passes the game check")
            break
    else:
        check(True, "every written voice take passes the game check")
    check(len(list(audio.glob("hurt_*.wav"))) == 2, "two pain sounds became hurt_0/1")
    rifle = [e["origin"] for e in json.loads(process.MANIFEST.read_text(encoding="utf-8"))["rifle"]]
    check(sorted(rifle) == [f"ARN180_Shot_Close_{k:02d}.wav" for k in range(1, 5)], "rifle: the four clean takes of one gun (no double bang, no suppressed, no other gun)")
    check(len(list(audio.glob("rifle_far_*.wav"))) == 4, "rifle_far made from the close shots (no far recordings in the folder)")
    check(len(list(audio.glob("pistol_*.wav"))) - len(list(audio.glob("pistol_far_*.wav"))) == 3, "pistol: three takes")
    reload = json.loads(process.MANIFEST.read_text(encoding="utf-8"))["reload"]
    check(len(reload) == 1 and "MagOut" in reload[0]["origin"] and "BoltRelease" in reload[0]["origin"], "a full reload is put together from its parts")
    manifest = json.loads(process.MANIFEST.read_text(encoding="utf-8"))
    check("MagOut" in manifest.get("mag_out", [{}])[0].get("origin", "") and "BoltRelease" in manifest.get("bolt", [{}])[0].get("origin", "")
          and (audio / "mag_out_0.wav").exists() and (audio / "bolt_0.wav").exists(),
          "the reload parts are also kept on their own (mag_out, bolt) for the timed reload")
    dec = json.loads((ac.PICK / "decisions.json").read_text(encoding="utf-8"))
    check(sorted(k for k, v in dec.items() if k.startswith("rifle/")) == [f"rifle/ron_ARN180_Shot_Close_{k:02d}.wav" for k in range(1, 5)],
          "the take-picking tool shows the chosen rifle takes as 'use'")
    backups = list(ir.BACKUP.glob("*/*"))
    check(any(p.name == "voice_down_0_0.wav" for p in backups) and any(p.name == "door_0.wav" for p in backups), "replaced and removed files are in the backup")
    check(not (audio / "door_0.wav").exists() and not (audio / "rifle_9.wav.import").exists(), "the final check removed the empty old file and the stale import")
    check(ir.verify_all(ac.load_catalog(), False, None) == [], "afterwards every game file passes the check")
    check("## 최종 검사" in report and "door_0.wav" in report, "the report lists the final check")

    # a take that no longer says its line after processing is swapped for another one
    def damaged(x16):  # the processed copy (levelled, so its peak is lower than the 0.8 of the source) is unrecognizable
        text, c, nsp = fake_asr(x16)
        return ("", 0.0, 0.9) if text == "Drop the weapon!" and np.abs(x16).max() < 0.7 else (text, c, nsp)

    ir.load_asr = lambda model: (damaged, "stand-in (test, damaged)")
    run(["--no-godot", "--only", "voice", "--voice-dir", str(vo)])
    ctx = json.loads((ir.WORK / "choices.json").read_text(encoding="utf-8"))
    srcs = {t["source"] for c in ctx["voice"]["commands"].values() for s in c for t in s["takes"]}
    check("Eli_DropWeapon_01.wav" not in srcs and any(f["file"] == "Eli_DropWeapon_01.wav" for f in ctx["voice"]["fixes"]),
          "a take that is damaged by processing is replaced and reported")
    check(len(list(audio.glob("voice_weapon_drop_*.wav"))) == 16, "its sentence slots are still all filled")

    # pins.json: files chosen by hand win over the automatic choice
    ir.load_asr = lambda model: (fake_asr, "stand-in (test)")
    (ir.WORK / "pins.json").write_text(json.dumps({
        "voice": {"down": [["Eli_Freeze_01.wav"], [], [], []]},
        "hurt": ["Eli_Pain_02.wav"],
        "weapons": {"rifle": ["SA58_Shot_Close_01.wav", "Missing.wav"], "pistol": [],
                    "reload": [[["ARN180_MagOut_01.wav", 0.0, 0.5], ["ARN180_BoltRelease_01.wav", 0.6, 0.8]]]}}), encoding="utf-8")
    run(["--no-godot", "--voice-dir", str(vo), "--weapons-dir", str(wp)])
    manifest = json.loads(process.MANIFEST.read_text(encoding="utf-8"))
    check(sorted(p.name for p in audio.glob("voice_down_*.wav")) == ["voice_down_0_0.wav"], "a pinned command plays exactly its pinned takes")
    check(len(list(audio.glob("voice_freeze_*.wav"))) == 16, "a command without pins is still chosen automatically")
    check(sorted(p.name for p in audio.glob("hurt_*.wav")) == ["hurt_0.wav"], "the pinned pain sound")
    check([e["origin"] for e in manifest["rifle"]] == ["SA58_Shot_Close_01.wav"], "the pinned rifle take; a name that is not in the folder is left out")
    check(len(list(audio.glob("rifle_far_*.wav"))) == 1, "the far set follows the pinned rifle")
    check(len(list(audio.glob("pistol_[0-9].wav"))) == 3, "an empty pin list leaves the sound as it is")
    check(manifest["reload"][0]["origin"] == "ARN180_MagOut_01.wav + ARN180_BoltRelease_01.wav", "pinned parts are mixed into one take")
    check(ir.verify_all(ac.load_catalog(), False, None) == [], "every game file still passes the check")

print("ALL PASS" if failed == 0 else f"{failed} FAILED")
sys.exit(1 if failed else 0)
