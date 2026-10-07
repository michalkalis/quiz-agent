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
import re
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "apps/ios-app/Hangs/Hangs/Fonts"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868

# Brand values mirror Palette in apps/ios-app/Hangs/Hangs/Utilities/Theme.swift.
VARIANTS = {
    # a: light studio, condensed display caption, app in light mode
    "a": {"bg": "#F6F7F9", "ink": "#0E1A2B", "accent": "#FF3D8F", "font": "Anton", "upper": True, "size": 128, "shot": "light", "glow": "rgba(14,26,43,.14)"},
    # b: brand pink field, white caption, app in light mode
    "b": {"bg": "#FF3D8F", "ink": "#FFFFFF", "accent": "#0E1A2B", "font": "Anton", "upper": True, "size": 128, "shot": "light", "glow": "rgba(120,0,50,.35)"},
    # c: night, sentence-case Inter caption, app in dark mode
    "c": {"bg": "#161616", "ink": "#F4F4F4", "accent": "#FF3D8F", "font": "Inter", "upper": False, "size": 112, "shot": "dark", "glow": "rgba(255,61,143,.22)"},
}


def caption_html(text: str) -> str:
    parts = re.split(r"\*(.+?)\*", html.escape(text))
    return "".join(f'<em>{p}</em>' if i % 2 else p for i, p in enumerate(parts))


def page(v: dict, caption: str, shot: Path) -> str:
    weight = 400 if v["font"] == "Anton" else 700
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: Anton; src: url('{(FONTS / "Anton-Regular.ttf").as_uri()}'); }}
@font-face {{ font-family: Inter; font-weight: 700; src: url('{(FONTS / "Inter-Bold.ttf").as_uri()}'); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; background: {v["bg"]}; }}
.cap {{ position: absolute; left: 110px; right: 110px; top: 190px; color: {v["ink"]};
  font: {weight} {v["size"]}px/1.12 {v["font"]}, sans-serif; letter-spacing: {"0.5px" if v["upper"] else "-2px"};
  text-transform: {"uppercase" if v["upper"] else "none"}; text-wrap: balance; }}
.cap em {{ font-style: normal; color: {v["accent"]}; }}
.shot {{ position: absolute; left: 50%; top: 700px; width: 1060px; transform: translateX(-50%);
  border-radius: 92px; box-shadow: 0 40px 120px {v["glow"]}, 0 0 0 10px rgba(255,255,255,{.0 if v["shot"] == "dark" else .55}); }}
</style></head><body><div class="cap">{caption_html(caption)}</div><img class="shot" src="{shot.as_uri()}"></body></html>"""


def render(doc: str, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "frame.html"
        src.write_text(doc)
        png = Path(tmp) / "frame.png"
        subprocess.run([CHROME, "--headless=new", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--allow-file-access-from-files", f"--window-size={W},{H}", f"--screenshot={png}", src.as_uri()],
                       check=True, capture_output=True)
        Image.open(png).convert("RGB").crop((0, 0, W, H)).save(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_dir", type=Path)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--variants", default="a,b,c")
    ap.add_argument("--locales", default="en,sk,cs")
    args = ap.parse_args()
    cfg = json.loads((Path(__file__).parent / "captions.json").read_text())
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
                render(page(v, cfg["captions"][loc][scene], shot), out)
                print(out)


if __name__ == "__main__":
    main()
