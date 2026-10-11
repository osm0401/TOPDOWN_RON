"""Matching rules of the Ready or Not import (import_ron.py), kept free of audio so they are easy to
test: text similarity of spoken lines, file name words, numbered file groups (the line table), weapon
classes and sound layers, and how the found lines fill the game's voice slots.
"""
import difflib
import re
import unicodedata
from collections import defaultdict

CONTRACTIONS = {"don't": "do not", "dont": "do not", "i'm": "i am", "im": "i am", "you're": "you are",
                "can't": "can not", "won't": "will not", "it's": "it is", "that's": "that is", "i'll": "i will",
                "let's": "let us", "we're": "we are", "they're": "they are"}
FILLER = {"uh", "um", "ah", "oh", "er", "hmm", "uhh", "umm"}
STOP = {"the", "a", "an", "your", "you", "it", "and", "me", "i", "to", "now", "is", "this", "are", "am", "do", "of", "on"}
NOISE_MARK = re.compile(r"[\[\(\*]([^\]\)\*]*)[\]\)\*]")  # whisper's [grunts], (groans), *gasps*


# ---- spoken text --------------------------------------------------------------

def words(text: str) -> list[str]:
    """Lowercase words without punctuation, contractions spelled out, filler sounds dropped."""
    t = unicodedata.normalize("NFKC", text).lower().replace("’", "'").replace("`", "'")
    t = NOISE_MARK.sub(" ", t)
    out = []
    for w in re.findall(r"[a-z0-9']+", t):
        w = w.strip("'")
        if not w or w in FILLER:
            continue
        out.extend(CONTRACTIONS.get(w, w).split())
    return out


def similarity(a: str, b: str) -> float:
    """0..1: how close two whole utterances are (word order and spelling both count). A line with
    extra words loses points, so "Hands up!" and "Hands up now!" stay apart."""
    wa, wb = words(a), words(b)
    if not wa or not wb:
        return 0.0
    w = difflib.SequenceMatcher(None, wa, wb).ratio()
    c = difflib.SequenceMatcher(None, " ".join(wa), " ".join(wb)).ratio()
    return round(0.5 * w + 0.5 * c, 3)


def noise_marks(text: str) -> list[str]:
    """Descriptions of non-speech sounds the recognizer wrote, e.g. ["grunts"] for "[grunts]"."""
    return [m.strip().lower() for m in NOISE_MARK.findall(text) if m.strip()]


# ---- file names -----------------------------------------------------------------

_TRAIL = re.compile(r"^(?P<pre>.*?)(?:[\s_\-.]*[\(\[]?(?P<n>\d{1,4})[\)\]]?)$")


def split_number(stem: str) -> tuple[str, int | None]:
    """'HandsUp_03' -> ('HandsUp', 3), 'Yell (2)' -> ('Yell', 2). A single digit glued to letters
    ('M4A1') is part of the name, not a take number."""
    m = _TRAIL.match(stem)
    if not m or m.group("n") is None or not m.group("pre"):
        return stem, None
    pre, n = m.group("pre"), m.group("n")
    glued = m.start("n") > 0 and stem[m.start("n") - 1].isalpha()
    if glued and len(n) < 2:
        return stem, None
    return pre.rstrip(" _-."), int(n)


def name_parts(stem: str) -> list[str]:
    """camelCase and letter / digit parts in order: 'M4A1_ShotClose' -> m, 4, a, 1, shot, close."""
    return [p.lower() for chunk in re.split(r"[^A-Za-z0-9]+", stem) if chunk
            for p in re.findall(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+", chunk)]


def name_tokens(stem: str) -> set[str]:
    """Words of a file name: whole chunks between separators plus their camelCase and letter / digit
    parts, all lowercase. 'M4A1_ShotClose_01' -> m4a1, shotclose, shot, close, m, 4, a, 1, 01."""
    out = {c.lower() for c in re.split(r"[^A-Za-z0-9]+", stem) if c}
    return out | set(name_parts(stem))


def group_key(rel_path: str) -> str:
    """Files that are takes of one sound share this: the path without the take number."""
    parts = rel_path.replace("\\", "/").rsplit("/", 1)
    folder, name = (parts[0] + "/", parts[1]) if len(parts) == 2 else ("", parts[0])
    stem = name.rsplit(".", 1)[0]
    return (folder + split_number(stem)[0]).lower()


def phrase_in_name(phrase: str, tokens: set[str], joined: str) -> bool:
    """A file name that spells out a line, e.g. 'Yell_DropTheWeapon_02' for "Drop the weapon!".
    Needs the whole line glued together in the name, or every content word when there are two or more."""
    ws = words(phrase)
    if not ws:
        return False
    for glued in ("".join(ws), re.sub(r"[^a-z0-9]", "", phrase.lower())):  # "donotmove" and "dontmove"
        if len(glued) >= 6 and glued in joined:
            return True
    have = set(tokens) | {w for t in tokens for w in CONTRACTIONS.get(t, t).split()}
    content = [w for w in ws if w not in STOP]
    return len(content) >= 2 and all(w in have for w in content)


def table_group(rel_paths: list[str], table_ns: list[int], hint: list[str]) -> tuple[dict[int, str], dict]:
    """The numbered file group the line table refers to: N -> file. A group fits when its take
    numbers cover the table (counting from 0 or from 1); a name with a hint word ('HandsUp',
    'Comply'...) or exactly as many files as the table wins ties."""
    groups: dict[str, dict[int, str]] = defaultdict(dict)
    for rel in rel_paths:
        stem = rel.replace("\\", "/").rsplit("/", 1)[-1].rsplit(".", 1)[0]
        pre, n = split_number(stem)
        if n is not None:
            groups[group_key(rel)][n] = rel
    want = sorted(set(table_ns))
    best, best_score, info = {}, 0.0, {}
    for key, members in groups.items():
        nums = set(members)
        for base in sorted({0, 1, min(nums)}):
            covered = [n for n in want if n + base in nums]
            cover = len(covered) / max(len(want), 1)
            if cover < 0.8:
                continue
            tokens = name_tokens(key.rsplit("/", 1)[-1])
            score = cover + (0.5 if tokens & set(hint) else 0.0) + (0.2 if len(nums) == len(want) else 0.0) - 0.001 * abs(len(nums) - len(want))
            if score > best_score:
                best_score = score
                best = {n: members[n + base] for n in covered}
                info = {"group": key, "base": base, "files": len(nums), "covered": len(covered), "hint": bool(tokens & set(hint))}
    return best, info


# ---- weapons ----------------------------------------------------------------------

def weapon_info(rel_path: str, cfg: dict) -> dict:
    """Class (rifle / smg / pistol / shotgun / ''), sound layer and weapon id of a weapon file,
    read from its name and folder. Layers: shot, far, tail, sub, mech, reload, mag_out, mag_in,
    bolt, taser, flesh_impact, impact, other; 'excluded' names why a file is never used."""
    path = rel_path.replace("\\", "/")
    stem = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    pre, _ = split_number(stem)
    tokens = name_tokens(pre)
    for folder in path.split("/")[:-1]:
        tokens |= name_tokens(folder)
    lay = {k: set(v) for k, v in cfg["layers"].items()}
    cls = ""
    for name, words_ in cfg["classes"].items():
        if tokens & set(words_):
            cls = name
            break
    excluded = sorted(tokens & set(cfg["exclude"]))
    has_mag = bool(tokens & lay["mag"])
    if tokens & lay["taser"]:
        layer = "taser"
    elif tokens & lay["impact"] and tokens & lay["flesh"]:
        layer = "flesh_impact"
    elif tokens & lay["impact"]:
        layer = "impact"
    elif tokens & lay["reload"]:
        layer = "reload"
    elif tokens & {"magout", "magazineout", "eject"} or (has_mag and tokens & (lay["mag_out"] - {"in"})):
        layer = "mag_out"
    elif tokens & {"magin", "magazinein", "insert", "insertion"} or (has_mag and tokens & (lay["mag_in"] - {"out"})):
        layer = "mag_in"
    elif tokens & lay["bolt"]:
        layer = "bolt"
    elif tokens & lay["far"]:
        layer = "far"
    elif tokens & lay["tail"]:
        layer = "tail"
    elif tokens & lay["sub"]:
        layer = "sub"
    elif tokens & lay["mech"] and not tokens & lay["shot"]:
        layer = "mech"
    elif tokens & lay["shot"] or cls:
        layer = "shot"
    else:
        layer = "other"
    # weapon id: the name without layer words, so M4A1ShotClose and M4A1_Shot_Far are one weapon
    generic = set().union(*lay.values()) | {"wpn", "weapon", "weapons", "gun", "sfx", "layer", "int", "ext", "interior",
                                            "exterior", "indoor", "outdoor", "single", "auto", "var", "variation"}
    ident = "".join(p for p in name_parts(pre) if p not in generic) or pre.lower()
    folder = path.rsplit("/", 1)[0].lower() if "/" in path else ""
    return {"class": cls, "layer": layer, "weapon": (folder + "/" + ident) if folder else ident,
            "group": group_key(path), "excluded": excluded, "tokens": sorted(tokens)}


def preference(tokens: list[str], prefer: dict) -> float:
    return sum(float(v) for k, v in prefer.items() if k in tokens)


# ---- voice slots --------------------------------------------------------------------

def distribute(own: list[list[str]], pool: list[str], takes: int) -> list[list[str]]:
    """Takes for every sentence of one command: first the lines found for that sentence (best first),
    then the least used other lines of the same command, so every found line plays somewhere and
    no sentence plays the same file twice."""
    used: dict[str, int] = defaultdict(int)
    out = []
    for lines in own:
        slot = []
        for f in lines:
            if f not in slot and len(slot) < takes:
                slot.append(f)
                used[f] += 1
        out.append(slot)
    for slot in out:
        while len(slot) < takes:
            spare = [f for f in pool if f not in slot]
            if not spare:
                break
            f = min(spare, key=lambda p: (used[p], pool.index(p)))
            slot.append(f)
            used[f] += 1
    return out
