"""Compose App Store screenshots: raw simulator capture + caption on a brand background.

Usage: python3 scripts/store_screenshots/render.py <raw_dir> <out_dir> [--variants a,b,c] [--locales en,sk,cs]
Raw captures are expected as <raw_dir>/<locale>/<scene>-<light|dark>.png, falling back to
<raw_dir>/<scene>-<light|dark>.png. Output: <out_dir>/<variant>/<locale>/<NN>-<scene>.png at
1320x2868 (6.9" iPhone), flattened without alpha as App Store Connect requires.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "apps/ios-app/Hangs/Hangs/Fonts"
W, H = 1320, 2868

# Never the everyday desktop Chrome: render with Playwright's bundled headless Chromium
# (`uvx playwright install chromium-headless-shell`), or point CHROME_BIN at Chrome for Testing.
PLAYWRIGHT_CACHE = Path.home() / "Library/Caches/ms-playwright"


def chrome_bin() -> str:
    if os.environ.get("CHROME_BIN"):
        return os.environ["CHROME_BIN"]
    shells = sorted(
        PLAYWRIGHT_CACHE.glob("chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"),
        key=lambda p: int(p.parts[-3].rsplit("-", 1)[1]),
    )
    if not shells:
        raise SystemExit("No headless Chromium: run `uvx playwright install chromium-headless-shell` or set CHROME_BIN")
    return str(shells[-1])


# Brand values mirror Palette in apps/ios-app/Hangs/Hangs/Utilities/Theme.swift (#194 redesign,
# #198 colours): grey page, ink type, cobalt as the one accent; captions in Rethink Sans, the
# app's content font. Variants b and c predate the redesign; only their font changed.
REDESIGN = {"bg": "#E8EAEE", "ink": "#111216", "accent": "#2C45F5", "upper": False, "size": 108, "shot": "light", "glow": "rgba(17,18,22,.14)"}
VARIANTS = {
    # a: the store set. Grey page, ink caption with cobalt accent words, app in light mode
    "a": REDESIGN,
    # b: brand pink field, white caption, app in light mode (pre-redesign)
    "b": {"bg": "#FF3D8F", "ink": "#FFFFFF", "accent": "#0E1A2B", "upper": True, "size": 128, "shot": "light", "glow": "rgba(120,0,50,.35)"},
    # c: night, app in dark mode (pre-redesign)
    "c": {"bg": "#161616", "ink": "#F4F4F4", "accent": "#FF3D8F", "upper": False, "size": 112, "shot": "dark", "glow": "rgba(255,61,143,.22)"},
    # p: variant a plus a lifestyle photo behind the caption on scenes listed under "photos" in captions.json
    "p": REDESIGN,
}


def caption_html(text: str) -> str:
    # sk/cs typography: a one-letter word (s, a, v, k) never ends a line
    text = re.sub(r"(?<!\S)(\w) ", "\\1\u00a0", text)
    parts = re.split(r"\*(.+?)\*", html.escape(text))
    return "".join(f'<em>{p}</em>' if i % 2 else p for i, p in enumerate(parts))


def page(v: dict, caption: str, shot: Path, photo: Path | None = None) -> str:
    if photo:  # photo fills the upper part and fades into the background; caption turns white on it
        v = {**v, "ink": "#FFFFFF", "accent": "#8C9BFF"}
        extra = f"""
.photo {{ position: absolute; inset: 0 0 auto 0; height: 1900px; background: url('{photo.as_uri()}') center 35% / cover; }}
.photo::after {{ content: ""; position: absolute; inset: 0;
  background: linear-gradient(180deg, rgba(17,18,22,.62) 0%, rgba(17,18,22,.18) 34%, rgba(17,18,22,0) 55%, {v["bg"]} 100%); }}
.cap {{ text-shadow: 0 4px 30px rgba(0,0,0,.35); }}
.shot {{ top: 900px !important; width: 960px !important; }}"""
        layer = '<div class="photo"></div>'
    else:
        extra, layer = "", ""
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Rethink Sans"; font-weight: 800; src: url('{(FONTS / "RethinkSans-ExtraBold.ttf").as_uri()}'); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; background: {v["bg"]}; }}
.cap {{ position: absolute; left: 110px; right: 110px; top: 190px; color: {v["ink"]};
  font: 800 {v["size"]}px/1.08 "Rethink Sans", sans-serif; letter-spacing: {"0.5px" if v["upper"] else "-1px"};
  text-transform: {"uppercase" if v["upper"] else "none"}; text-wrap: balance; }}
.cap em {{ font-style: normal; color: {v["accent"]}; }}
.shot {{ position: absolute; left: 50%; top: 700px; width: 1060px; transform: translateX(-50%);
  border-radius: 92px; box-shadow: 0 40px 120px {v["glow"]}, 0 0 0 10px rgba(255,255,255,{.0 if v["shot"] == "dark" else .55}); }}{extra}
</style></head><body>{layer}<div class="cap">{caption_html(caption)}</div><img class="shot" src="{shot.as_uri()}"></body></html>"""


# Simulator captures include the Dynamic Island only on some screens; draw it on every frame
# so the set looks consistent (iPhone 17 Pro Max, 1320x2868 capture).
ISLAND = (472, 42, 847, 151)


def with_island(shot: Path, tmp: Path) -> Path:
    from PIL import ImageDraw

    im = Image.open(shot).convert("RGB")
    ImageDraw.Draw(im).rounded_rectangle(ISLAND, radius=(ISLAND[3] - ISLAND[1]) // 2, fill=(0, 0, 0))
    out = tmp / f"{shot.parent.name}-{shot.name}"
    im.save(out)
    return out


def render(doc: str, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "frame.html"
        src.write_text(doc)
        png = Path(tmp) / "frame.png"
        subprocess.run([chrome_bin(), "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--allow-file-access-from-files", f"--window-size={W},{H}", f"--screenshot={png}", src.as_uri()],
                       check=True, capture_output=True)
        Image.open(png).convert("RGB").crop((0, 0, W, H)).save(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_dir", type=Path)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--variants", default="a,b,c")
    ap.add_argument("--locales", default="en,sk,cs")
    ap.add_argument("--photo-dir", type=Path, help="lifestyle photos for variant p (file names from captions.json photos)")
    args = ap.parse_args()
    cfg = json.loads((Path(__file__).parent / "captions.json").read_text())
    island_dir = Path(tempfile.mkdtemp())
    for vk in args.variants.split(","):
        v = VARIANTS[vk]
        for loc in args.locales.split(","):
            for n, scene in enumerate(cfg["scenes"], 1):
                name = f"{scene}-{v['shot']}.png"
                shot = next((p for p in (args.raw_dir / loc / name, args.raw_dir / name) if p.exists()), None)
                if shot is None:
                    print(f"skip {vk}/{loc}/{scene}: no {name}")
                    continue
                out = args.out_dir / vk / loc / f"{n:02d}-{scene}.png"
                photo_name = cfg.get("photos", {}).get(scene) if vk == "p" else None
                photo = args.photo_dir / photo_name if photo_name and args.photo_dir else None
                render(page(v, cfg["captions"][loc][scene], with_island(shot, island_dir), photo), out)
                print(out)


if __name__ == "__main__":
    main()
