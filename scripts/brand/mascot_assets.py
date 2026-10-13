"""Regenerate every logo asset from the mascot master (docs/design/brand/trubbo-mascot.svg).

The mascot (a flat orangutan head) is the Trubbo logo since 2026-10-13. Outputs:
  · iOS app icon layers (AppIcon.icon) — one layer per master group, flat (no Liquid Glass bevel)
  · iOS in-app mark (Assets.xcassets/TrubboMascot.imageset, vector PDF)
  · website favicon.svg / favicon.png / apple-touch-icon.png / mascot.svg / og.png / mail-logo.png

Run from the repo root: python3 scripts/brand/mascot_assets.py
Needs Xcode (swift) for the PDF and Playwright's headless Chromium for the PNGs.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

MASTER = ROOT / "docs/design/brand/trubbo-mascot.svg"
APP = ROOT / "apps/ios-app/Hangs/Hangs"
ICON = APP / "AppIcon.icon"
IMAGESET = APP / "Assets.xcassets/TrubboMascot.imageset"
WEB = ROOT / "apps/website/src"

COBALT = "#2C45F5"  # Theme.Hangs.Palette cobalt, the icon ground since #194
BG, INK = "#E8EAEE", "#111216"  # website --bg / --ink (light)
LAYERS = ["ears", "mane", "face", "features"]  # bottom first
GRID_TILE = (
    "translate(15 10.75) scale(0.85)"  # head on a 200 tile, as approved on the canvas
)


def chrome_bin() -> str:
    """Playwright's headless Chromium, never the everyday desktop Chrome (as scripts/store_screenshots)."""
    if os.environ.get("CHROME_BIN"):
        return os.environ["CHROME_BIN"]
    cache = Path.home() / "Library/Caches/ms-playwright"
    shells = sorted(
        cache.glob(
            "chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"
        ),
        key=lambda p: int(p.parts[-3].rsplit("-", 1)[1]),
    )
    if not shells:
        raise SystemExit(
            "No headless Chromium: run `uvx playwright install chromium-headless-shell` or set CHROME_BIN"
        )
    return str(shells[-1])


def groups() -> dict[str, str]:
    found = dict(re.findall(r'<g id="(\w+)">(.*?)</g>', MASTER.read_text()))
    if list(found) != LAYERS:
        raise SystemExit(
            f"{MASTER.name}: expected groups {LAYERS}, found {list(found)}"
        )
    return found


def head(g: dict[str, str]) -> str:
    return "".join(g[k] for k in LAYERS)


def write_icon(g: dict[str, str]) -> None:
    assets = ICON / "Assets"
    for old in assets.glob("*.svg"):
        old.unlink()
    for name in LAYERS:  # 100-unit icon grid = the 200 tile at half scale
        (assets / f"{name}.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100">'
            f'<g transform="scale(0.5) {GRID_TILE}">{g[name]}</g></svg>'
        )
    layer = (
        lambda name: {
            "glass": False,  # founder: flat shapes, no outlines; glass draws a bevelled rim on each layer
            "hidden": False,
            "image-name": f"{name}.svg",
            "name": name,
            "opacity": 1,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }
    )
    icon = {
        "fill": {"solid": "srgb:0.17255,0.27059,0.96078,1.00000"},
        "groups": [
            {
                "layers": [
                    layer(n) for n in reversed(LAYERS)
                ],  # Icon Composer lists the top layer first
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.4},
            }
        ],
        "supported-platforms": {"squares": ["iOS"]},
    }
    (ICON / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")


def tile_svg(g: dict[str, str], radius: float) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">'
        f'<rect width="200" height="200" rx="{radius}" fill="{COBALT}"/>'
        f'<g transform="{GRID_TILE}">{head(g)}</g></svg>'
    )


def bare_svg(g: dict[str, str]) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="21 16 158 178">{head(g)}</svg>'


def font_face() -> str:
    url = (WEB / "rethink-sans-latin.woff2").as_uri()
    return f"@font-face{{font-family:R;src:url({url});font-weight:400 800}}"


def lockup(g: dict[str, str], px: int) -> str:
    """Mascot beside the wordmark, as the app's HangsBrandMark draws it (mark 1.3x the word size)."""
    return (
        f'<div style="display:flex;align-items:center;gap:{px * 0.22:.0f}px">'
        f'<svg viewBox="21 16 158 178" style="height:{px * 1.3:.0f}px">{head(g)}</svg>'
        f'<span style="font:800 {px}px R;letter-spacing:{-px * 0.03:.1f}px;color:{INK}">trubbo</span></div>'
    )


def screenshot(html: str, out: Path, w: int, h: int) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "page.html"
        page.write_text(
            f"<!doctype html><meta charset=utf-8><style>{font_face()}html,body{{margin:0}}</style>{html}"
        )
        subprocess.run(
            [
                chrome_bin(),
                "--headless",
                "--hide-scrollbars",
                "--force-device-scale-factor=1",
                f"--window-size={w},{h}",
                f"--screenshot={out}",
                "--default-background-color=00000000",
                page.as_uri(),
            ],
            check=True,
            capture_output=True,
        )


def write_web(g: dict[str, str]) -> None:
    (WEB / "favicon.svg").write_text(tile_svg(g, 44.7))
    (WEB / "mascot.svg").write_text(bare_svg(g))
    fill = lambda svg, s: (
        f'<div style="width:{s}px;height:{s}px">{svg.replace("<svg ", "<svg width=100% height=100% ", 1)}</div>'
    )
    screenshot(fill(tile_svg(g, 44.7), 32), WEB / "favicon.png", 32, 32)
    screenshot(
        fill(tile_svg(g, 0), 180), WEB / "apple-touch-icon.png", 180, 180
    )  # iOS rounds it itself
    cards = "".join(
        f'<div style="position:absolute;left:{x}px;top:{y}px;width:330px;height:440px;border-radius:30px;'
        f'background:{c};transform:rotate({r}deg)"></div>'
        for x, y, c, r in [
            (-120, 380, COBALT, -18),
            (860, 330, "#3FE0AE", -8),
            (1010, 190, "#FF6B2C", 12),
        ]
    )
    screenshot(
        f'<div style="position:relative;width:1200px;height:630px;overflow:hidden;background:{BG}">{cards}'
        f'<div style="position:absolute;inset:150px 230px 170px 230px;border-radius:44px;background:#FFF;'
        f'display:flex;align-items:center;justify-content:center;box-shadow:0 20px 60px rgba(17,18,22,.12)">'
        f"{lockup(g, 150)}</div></div>",
        WEB / "og.png",
        1200,
        630,
    )
    # e-mail signature: opaque white so it stays legible in dark-mode mail clients; shown at 140x48
    screenshot(
        f'<div style="width:280px;height:96px;background:#FFF;display:flex;align-items:center">{lockup(g, 60)}</div>',
        WEB / "mail-logo.png",
        280,
        96,
    )


def write_imageset(g: dict[str, str]) -> None:
    IMAGESET.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "mascot.svg"
        src.write_text(bare_svg(g))
        subprocess.run(
            [
                "xcrun",
                "swift",
                str(Path(__file__).with_name("svg_to_pdf.swift")),
                str(src),
                str(IMAGESET / "TrubboMascot.pdf"),
            ],
            check=True,
        )
    contents = {
        "images": [{"filename": "TrubboMascot.pdf", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }
    (IMAGESET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


if __name__ == "__main__":
    g = groups()
    write_icon(g)
    write_imageset(g)
    write_web(g)
    print("done: AppIcon.icon, TrubboMascot.imageset, website favicon/og/mail-logo")
