# assets/audio

Audio files here are NOT committed (see `.gitignore`): their licenses are not cleared for the
public repository yet. The game falls back to the synthesized stand-ins (`src/core/sfx_synth.gd`)
when a file is missing, so a fresh clone still has sound.

`data/audio.json` -> `samples` maps a sound name to the files that replace its stand-in.

| file | what | origin | license status |
|---|---|---|---|
| `rifle_1.wav` | assault rifle shot | generated with Stable Audio Open 1.0 on the author's PC (prompt: "single assault rifle gunshot, close microphone, loud sharp crack, short echo in a concrete room, realistic sound effect", seed 1, take 1), then mono / trimmed / faded in a script | Stability AI Community License: terms for the public repo and for selling the game still to be checked (stability.ai/license) |

Generator setup (outside the repo): `D:\tools\sao`, script `gen_sfx.py`.
