# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Build the Trubbo Beta app icon (AppIconBeta.icon) from the live AppIcon.icon.

#234 — Trubbo Beta: the TestFlight build is its own app next to the App Store
one, so the two must be told apart on the home screen. The beta icon is the
live Icon Composer icon plus one top layer: an orange band reading "BETA"
across the lower part. Everything else (fill, mascot layers) is copied, so
rerun this after scripts/brand/mascot_assets.py changes the live icon.

Run from the repo root: uv run scripts/brand/beta_icon.py
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/ios-app/Hangs/Hangs"
LIVE = APP / "AppIcon.icon"
BETA = APP / "AppIconBeta.icon"

SIZE = 1024  # Icon Composer canvas
BAND_TOP, BAND_BOTTOM = 720, 880  # inside the rounded-square mask
ORANGE = (255, 138, 0, 255)
WHITE = (255, 255, 255, 255)
LAYER = "beta-band.png"
FONT = ("/System/Library/Fonts/HelveticaNeue.ttc", 1)  # index 1 = Bold


def band() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, BAND_TOP, SIZE, BAND_BOTTOM), fill=ORANGE)
    font = ImageFont.truetype(FONT[0], 120, index=FONT[1])
    centre = (SIZE / 2, (BAND_TOP + BAND_BOTTOM) / 2)
    draw.text(centre, "BETA", font=font, fill=WHITE, anchor="mm")
    return img


def main() -> None:
    if BETA.exists():
        shutil.rmtree(BETA)
    shutil.copytree(LIVE, BETA)
    band().save(BETA / "Assets" / LAYER, optimize=True)

    icon = json.loads((BETA / "icon.json").read_text())
    layer = {
        "glass": False,
        "hidden": False,
        "image-name": LAYER,
        "name": "beta-band",
        "opacity": 1,
        "position": {"scale": 1, "translation-in-points": [0, 0]},
    }
    # Icon Composer draws the first layer of a group on top.
    icon["groups"].insert(0, {"layers": [layer]})
    (BETA / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
    print(f"wrote {BETA.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
