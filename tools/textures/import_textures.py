"""Free photo textures into the game: takes the zips (or folders) you downloaded from ambientCG or
Poly Haven (both CC0: free to use, no credit needed) and puts the right files where the game looks.

  python tools/textures/import_textures.py            # everything in assets/textures/_download/
  python tools/textures/import_textures.py --list     # the names the game knows, and what to search for
  python tools/textures/import_textures.py --dry-run  # only say what it would do

How: save each download as assets/textures/_download/<name>.zip (or unzip it into a folder
assets/textures/_download/<name>/), where <name> is a game name from --list, e.g. floor_wood.zip.
The script finds the colour picture and its maps by their usual file names and writes
  assets/textures/<set>/<name>.jpg           colour
  assets/textures/<set>/<name>_normal.jpg    normal map (OpenGL style; a DirectX one is turned round)
  assets/textures/<set>/<name>_rough.jpg     roughness
  assets/textures/<set>/<name>_ao.jpg        ambient occlusion
<set> is data/view3d.json characters.set. Pictures bigger than 2048 px are made smaller when Pillow
is installed (pip install pillow); without it they are copied as they are (a DirectX normal map then
needs Pillow, or download the GL one). Only standard Python otherwise.
"""
import argparse
import io
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_PX = 2048
IMAGE_EXT = (".jpg", ".jpeg", ".png")

# game name -> (what it is, words to search for on ambientcg.com / polyhaven.com)
NAMES = {
    "floor_wood": ("거실 나무 마루", "wood floor, parquet"),
    "floor_carpet": ("침실 짙은 남색 카펫", "carpet, fabric carpet"),
    "floor_office": ("사무실 회색 타일 카펫", "carpet tiles, office carpet"),
    "floor_kitchen": ("부엌 흑백 체크 타일", "tiles checker, floor tiles"),
    "floor_concrete": ("창고 콘크리트 바닥", "concrete floor"),
    "floor_corridor": ("복도 베이지 타일", "tiles, floor tiles beige"),
    "wall_warm": ("따뜻한 베이지 칠한 벽", "plaster, painted plaster"),
    "wall_blue": ("회청색 칠한 벽", "plaster, painted wall"),
    "wall_white": ("흰 칠한 벽", "plaster white"),
    "wall_yellow": ("연노랑 칠한 벽", "plaster, painted plaster"),
    "wall_corridor": ("회베이지 복도 벽", "plaster, painted wall"),
    "wall_block": ("창고 콘크리트 블록 벽", "concrete blocks, cinder block"),
    "wall_brick": ("바깥 붉은 벽돌", "bricks red"),
    "ground_grass": ("잔디", "grass"),
    "ground_sidewalk": ("보도블록", "paving stones"),
    "ground_asphalt": ("아스팔트", "asphalt, road"),
    # furniture (a picture covers 1 m of the piece)
    "wood_dark": ("가구: 짙은 나무", "wood dark, walnut"),
    "wood_mid": ("가구: 중간 나무", "wood, oak"),
    "wood_light": ("가구: 밝은 나무", "wood light, birch, pine"),
    "crate_wood": ("가구: 나무 상자", "planks, wood crate"),
    "door_wood": ("문: 나무", "wood door, wood veneer"),
    "fabric_grey": ("가구: 회색 천(소파)", "fabric grey, upholstery"),
    "fabric_green": ("가구: 초록 천", "fabric green"),
    "fabric_blue": ("가구: 파란 천", "fabric blue"),
    "fabric_red": ("가구: 빨간 천", "fabric red"),
    "fabric_beige": ("가구: 베이지 천", "fabric beige, linen"),
    "linen": ("가구: 침대 시트", "fabric white, cotton"),
    "stone": ("가구: 돌 상판", "marble, granite"),
    "plaster": ("가구: 회반죽", "plaster"),
}

# map -> file name patterns (lower case), best first
MAPS = {
    "color": [r"_color(?=_|$)", r"basecolor", r"base_color", r"albedo", r"_diff(use)?(?=_|$)", r"_col(?=_|$)"],
    "normal_gl": [r"normalgl", r"nor_gl", r"normal_gl", r"_normal_opengl"],
    "normal_dx": [r"normaldx", r"nor_dx", r"normal_dx", r"_normal(?=_|$)", r"_nrm(?=_|$)"],
    "rough": [r"roughness", r"_rough(?=_|$)"],
    "ao": [r"ambientocclusion", r"_ao(?=_|$)", r"_occlusion"],
}


def model_set() -> str:
    cfg = json.loads((ROOT / "data" / "view3d.json").read_text(encoding="utf-8"))
    return str(cfg["characters"].get("set", "")) or "gemini"


def files_of(src: Path) -> dict:
    """{file name: bytes loader} of the pictures in a zip or a folder (sub folders too)."""
    out = {}
    if src.is_file() and src.suffix.lower() == ".zip":
        z = zipfile.ZipFile(src)
        for n in z.namelist():
            if n.lower().endswith(IMAGE_EXT):
                out[n] = (lambda n=n, z=z: z.read(n))
    elif src.is_dir():
        for p in src.rglob("*"):
            if p.is_file() and p.suffix.lower() in IMAGE_EXT:
                out[str(p.relative_to(src))] = (lambda p=p: p.read_bytes())
    return out


def pick(files: dict) -> dict:
    """Which file is which map: the first name that fits, 2K files first when a download has several sizes."""
    found = {}
    names = sorted(files, key=lambda n: (not re.search(r"(2k|2048)", n.lower()), n))  # 2K first when a zip has several sizes
    for key, pats in MAPS.items():
        for pat in pats:
            hit = next((n for n in names if re.search(pat, Path(n).stem.lower().replace("-", "_").replace(" ", "_"))), None)
            if hit is not None and hit not in found.values():
                found[key] = hit
                break
    return found


def write(data: bytes, dest_noext: Path, src_name: str, flip_green: bool, dry: bool) -> str:
    ext = ".png" if src_name.lower().endswith(".png") else ".jpg"
    try:
        from PIL import Image  # optional
    except ImportError:
        Image = None
    im = None
    if Image is not None:
        try:
            im = Image.open(io.BytesIO(data))
        except Exception:  # not a picture Pillow knows: copied as it is
            im = None
    if im is not None:
        changed = False
        if max(im.size) > MAX_PX:
            im = im.resize((MAX_PX, MAX_PX * im.size[1] // im.size[0]), Image.LANCZOS)
            changed = True
        if flip_green:
            im = im.convert("RGB")
            r, g, b = im.split()
            g = g.point(lambda v: 255 - v)
            im = Image.merge("RGB", (r, g, b))
            changed = True
        if changed:
            dest = dest_noext.with_suffix(ext)
            if not dry:
                if im.mode not in ("RGB", "L"):
                    im = im.convert("RGB")
                im.save(dest, quality=92) if ext == ".jpg" else im.save(dest)
            return dest.name
    elif flip_green:
        raise RuntimeError("DirectX normal map needs Pillow to turn round (pip install pillow), or download the GL one")
    dest = dest_noext.with_suffix(ext)
    if not dry:
        dest.write_bytes(data)
    return dest.name


def import_one(src: Path, out_dir: Path, dry: bool) -> list:
    name = src.stem if src.is_file() else src.name
    files = files_of(src)
    found = pick(files)
    if "color" not in found:
        return [f"{name}: 색 사진(Color / diff)을 찾지 못함 — 건너뜀"]
    for old in out_dir.glob(name + "*.*"):  # a new download replaces every map of the old one
        if re.fullmatch(re.escape(name) + r"(_normal|_rough|_ao)?\.(png|jpg)", old.name) and not dry:
            old.unlink()
    lines = []
    lines.append(write(files[found["color"]](), out_dir / name, found["color"], False, dry))
    if "normal_gl" in found:
        lines.append(write(files[found["normal_gl"]](), out_dir / (name + "_normal"), found["normal_gl"], False, dry))
    elif "normal_dx" in found:
        try:
            lines.append(write(files[found["normal_dx"]](), out_dir / (name + "_normal"), found["normal_dx"], True, dry))
        except RuntimeError as e:
            lines.append(f"(노멀맵 건너뜀: {e})")
    for key, suffix in (("rough", "_rough"), ("ao", "_ao")):
        if key in found:
            lines.append(write(files[found[key]](), out_dir / (name + suffix), found[key], False, dry))
    return [f"{name}: " + ", ".join(lines)]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="names the game knows and what to search for")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--src", default=str(ROOT / "assets" / "textures" / "_download"))
    ap.add_argument("--out", default="", help="default: assets/textures/<set>")
    a = ap.parse_args(argv)
    if a.list:
        for k, (what, words) in NAMES.items():
            print(f"{k:16} {what:22} 검색어: {words}")
        return 0
    src = Path(a.src)
    out_dir = Path(a.out) if a.out else ROOT / "assets" / "textures" / model_set()
    if not src.is_dir():
        print(f"{src} 폴더가 없어요. 받은 zip을 <이름>.zip으로 여기에 넣어 주세요 (--list로 이름 보기).")
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    bad = 0
    for item in sorted(src.iterdir()):
        name = item.stem if item.is_file() else item.name
        if item.is_file() and item.suffix.lower() != ".zip":
            continue
        if name not in NAMES:
            print(f"{name}: 게임이 모르는 이름 — 건너뜀 (--list 참고)")
            bad += 1
            continue
        for line in import_one(item, out_dir, a.dry_run):
            print(line)
            bad += "건너뜀" in line and not line.startswith("(")
    print(f"\n넣은 곳: {out_dir}" + ("  (dry run: 아무것도 바꾸지 않음)" if a.dry_run else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
