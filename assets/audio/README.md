# assets/audio

Audio files here are NOT committed (see `.gitignore`): their licenses are not cleared for the
public repository yet. The game falls back to the synthesized stand-ins (`src/core/sfx_synth.gd`)
when a file is missing, so a fresh clone still has sound.

A file `<sound>_<n>.wav` (n = 0..15) replaces the stand-in of that sound (`GameAudio.SAMPLE_KEYS`).

- Footsteps by floor: `footstep_wood_<n>`, `footstep_tile_<n>`, `footstep_carpet_<n>`,
  `footstep_concrete_<n>`, `footstep_grass_<n>`, `footstep_asphalt_<n>` (which floor uses which:
  `data/audio.json` `step_surfaces`). Plain `footstep_<n>` files are used for floors that have
  no files of their own.
- Reload parts, played as the hands get there: `mag_out_<n>`, `mag_in_<n>`, `bolt_<n>`. With only
  `reload_<n>` files (a whole reload) and no parts, the whole take plays at the start instead.

| file | what | origin | license status |
|---|---|---|---|
| `rifle_1.wav` | assault rifle shot | generated with Stable Audio Open 1.0 on the author's PC (prompt: "single assault rifle gunshot, close microphone, loud sharp crack, short echo in a concrete room, realistic sound effect", seed 1, take 1), then mono / trimmed / faded in a script | Stability AI Community License: terms for the public repo and for selling the game still to be checked (stability.ai/license) |
| `voice_*.wav`, `hurt_*.wav`, `rifle*`, `pistol*`, `reload_*`, `mag_out_*`, `mag_in_*`, `bolt_*`, `taser_*`, `hit_*` (when imported) | officer lines of SWAT Eli and weapon sounds taken from Ready or Not by `tools/audio/import_ron.py`; `manifest.json` (`origin`) and `_import/REPORT.md` say which file each one came from | property of VOID Interactive: personal testing only, never commit or ship them; replace before any release |

Generator setup (outside the repo): `D:\tools\sao`, script `gen_sfx.py`.
