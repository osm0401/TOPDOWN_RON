"""Self-check of import_textures.py on made-up downloads (an ambientCG-style zip, a Poly Haven-style
folder, a zip without a colour picture). Runs in a temporary folder; nothing in assets/ is touched.

  python tools/textures/test_import_textures.py
"""
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import import_textures as it  # noqa: E402

failed = 0


def check(cond: bool, label: str) -> None:
    global failed
    print(("PASS " if cond else "FAIL ") + label)
    failed += 0 if cond else 1


with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    src = t / "dl"
    out = t / "out"
    src.mkdir()
    with zipfile.ZipFile(src / "floor_wood.zip", "w") as z:
        for n in ["WoodFloor041_1K-JPG_Color.jpg", "WoodFloor041_1K-JPG_NormalGL.jpg", "WoodFloor041_1K-JPG_NormalDX.jpg",
                  "WoodFloor041_1K-JPG_Roughness.jpg", "WoodFloor041_1K-JPG_AmbientOcclusion.jpg", "WoodFloor041_1K-JPG_Displacement.jpg",
                  "WoodFloor041.png"]:
            z.writestr(n, n.encode())
    ph = src / "wall_brick" / "textures"
    ph.mkdir(parents=True)
    for n in ["red_brick_diff_1k.jpg", "red_brick_nor_gl_1k.jpg", "red_brick_rough_1k.jpg", "red_brick_disp_1k.png"]:
        (ph / n).write_bytes(n.encode())
    with zipfile.ZipFile(src / "floor_carpet.zip", "w") as z:
        z.writestr("readme.txt", b"x")
        z.writestr("Carpet_Roughness.jpg", b"r")
    with zipfile.ZipFile(src / "not_a_name.zip", "w") as z:
        z.writestr("A_Color.jpg", b"c")
    code = it.main(["--src", str(src), "--out", str(out)])
    got = sorted(p.name for p in out.iterdir())
    check((out / "floor_wood.jpg").read_bytes() == b"WoodFloor041_1K-JPG_Color.jpg", "ambientCG zip: the colour picture")
    check((out / "floor_wood_normal.jpg").read_bytes() == b"WoodFloor041_1K-JPG_NormalGL.jpg", "ambientCG zip: the OpenGL normal map, not the DirectX one")
    check((out / "floor_wood_rough.jpg").exists() and (out / "floor_wood_ao.jpg").exists(), "ambientCG zip: roughness and occlusion")
    check((out / "wall_brick.jpg").read_bytes() == b"red_brick_diff_1k.jpg" and (out / "wall_brick_normal.jpg").read_bytes() == b"red_brick_nor_gl_1k.jpg"
          and (out / "wall_brick_rough.jpg").exists() and not (out / "wall_brick_ao.jpg").exists(), "Poly Haven folder: diff, nor_gl, rough")
    check(not any(n.startswith("floor_carpet") for n in got), "no colour picture: skipped")
    check(not any(n.startswith("not_a_name") for n in got), "an unknown name: skipped")
    check(code == 1, "skips are reported (exit 1)")
    (out / "floor_wood_ao.jpg").write_bytes(b"old")
    with zipfile.ZipFile(src / "floor_wood.zip", "w") as z:
        z.writestr("X_Color.jpg", b"new")
    it.main(["--src", str(src), "--out", str(out)])
    check((out / "floor_wood.jpg").read_bytes() == b"new" and not (out / "floor_wood_ao.jpg").exists(), "a new download replaces every map of the old one")

print("---- " + ("FAILED: %d" % failed if failed else "ALL PASSED"))
sys.exit(1 if failed else 0)
