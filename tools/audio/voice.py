"""Recording sheet and processing for the spoken lines (your own recordings, no AI voice needed).

  python tools/audio/voice.py sheet      # writes tools/audio/VOICE_SHEET.md: what to record and the file names
  python tools/audio/voice.py process    # assets/audio/_voice_raw/*.wav -> game files assets/audio/voice_*.wav

Name every recording like the sheet says and put it in assets/audio/_voice_raw/. `process` trims the
silence around the line, removes rumble, evens out the loudness between takes and writes the game file
with the same name. The game plays the recorded take that matches the sentence on screen; a sentence
without a recording keeps the synthesized shout.
"""
import json
import re
import sys
from pathlib import Path

from audio_common import AUDIO, ROOT, VOICE_RAW, highpass, level_voice, read_mono, trim_silence, write_wav

COMMANDS = ROOT / "data" / "commands.json"
SHEET = Path(__file__).with_name("VOICE_SHEET.md")
TAKES = 4  # take = a different voice or a different mood (the game never plays the same take twice in a row)
SCREAM_LINE = "꺄악!"
DIRECTION = {
    "weapon_drop": "단호하게, 크게 외침 (경찰이 총을 든 사람에게)",
    "down": "크고 급박하게 (바닥에 엎드리라는 명령)",
    "freeze": "낮고 위협적으로, 힘을 줘서",
    "turn": "침착하지만 단호하게",
}


def command_lines() -> dict[str, list[str]]:
    d = json.loads(COMMANDS.read_text(encoding="utf-8"))
    return {k: v for k, v in d.items() if isinstance(v, list)}


def valid_name(stem: str, keys: list[str]) -> bool:
    pattern = rf"voice_(?:{'|'.join(map(re.escape, keys))})_\d+_\d+|voice_npc_scream_\d+|hurt_\d+|scream_\d+"
    return re.fullmatch(pattern, stem) is not None


def sheet_text(lines: dict[str, list[str]]) -> str:
    out = ["# 대사 녹음 안내", "",
           "마이크로 직접 녹음하면 가장 사실적이고 권리 문제도 없습니다. 같은 문장을 **최대 4번(테이크 0~3)**, "
           "다른 사람이나 다른 분위기로 녹음하면 게임이 번갈아 씁니다.", "",
           "## 녹음 요령", "- 조용한 방, 입에서 한 뼘 정도 거리, WAV 또는 변환 가능한 파일(44.1~48 kHz)",
           "- 문장 앞뒤로 0.5초 정도 비워 두면 도구가 알아서 자릅니다", "- 크게 외치되 마이크가 찌그러지지 않게(너무 가까이 대지 않기)",
           "- 파일은 `assets/audio/_voice_raw/`에 아래 이름 그대로 저장하고 `python tools/audio/voice.py process` 실행", "",
           "## 명령 대사 (경찰)", "", "| 문장 | 분위기 | 파일 이름 (테이크 0~3) |", "|---|---|---|"]
    for key, options in lines.items():
        for i, text in enumerate(options):
            out.append(f"| {text} | {DIRECTION.get(key, '')} | `voice_{key}_{i}_0.wav` ~ `voice_{key}_{i}_{TAKES - 1}.wav` |")
    out += ["", "## 민간인/적 소리", "", "| 소리 | 분위기 | 파일 이름 |", "|---|---|---|",
            f"| {SCREAM_LINE} | 민간인이 놀라서 지르는 비명 | `voice_npc_scream_0.wav` ~ `voice_npc_scream_{TAKES - 1}.wav` |",
            "| (비명, 말 없이) | 놀람과 공포의 긴 비명 | `scream_0.wav` ~ `scream_3.wav` |",
            "| (신음) | 총에 맞았을 때 짧은 신음과 숨 | `hurt_0.wav` ~ `hurt_3.wav` |", ""]
    return "\n".join(out)


def process_voices(src: Path = VOICE_RAW, dst: Path = AUDIO) -> list[str]:
    keys = list(command_lines())
    done = []
    for path in sorted(src.glob("*.wav")):
        if not valid_name(path.stem, keys):
            print(f"skip {path.name}: the name does not match the recording sheet")
            continue
        x, sr = read_mono(path)
        x = level_voice(highpass(trim_silence(x, sr), sr, 90.0))
        write_wav(dst / path.name, x, sr)
        done.append(path.name)
        print(f"ok   {path.name}  {len(x) / sr:.2f} s")
    return done


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "sheet":
        SHEET.write_text(sheet_text(command_lines()), encoding="utf-8")
        print("wrote", SHEET)
    elif cmd == "process":
        VOICE_RAW.mkdir(parents=True, exist_ok=True)
        print(f"{len(process_voices())} voice file(s) processed")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
