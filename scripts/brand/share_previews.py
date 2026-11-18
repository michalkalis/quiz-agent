"""Link preview images for the share pages: og-play.png (trubbo.app/play) and og-join.png (trubbo.app/join).

#240.9: chat apps show these when a friend sends a Trubbo link. They carry no words, so one image
works for every language; the page's og:title and og:description say what the link is.
Same ground and tilted cards as og.png (mascot_assets.py), drawn with the same mascot and wordmark.

Run from the repo root: python3 scripts/brand/share_previews.py
Needs Playwright's headless Chromium and ImageMagick (`magick`, to strip and compress the PNGs).
"""

from __future__ import annotations

import subprocess

from mascot_assets import BG, COBALT, WEB, groups, head, lockup, screenshot

GREEN, ORANGE, PURPLE, LINE = "#3FE0AE", "#FF6B2C", "#7A5CFF", "#C9CCD4"
TICK = '<path d="M30 52 L45 66 L71 36" fill="none" stroke="#FFF" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>'
CROSS = '<path d="M35 35 L65 65 M65 35 L35 65" fill="none" stroke="#FFF" stroke-width="10" stroke-linecap="round"/>'
PERSON = '<circle cx="50" cy="38" r="15" fill="#FFF"/><path d="M22 80 C22 60 78 60 78 80 Z" fill="#FFF"/>'
PLUS = f'<path d="M50 30 V70 M30 50 H70" stroke="{LINE}" stroke-width="9" stroke-linecap="round"/>'


def frame(body: str) -> str:
    """og.png's ground: light grey with three tilted cards, a white card in the middle."""
    cards = "".join(
        f'<div style="position:absolute;left:{x}px;top:{y}px;width:330px;height:440px;border-radius:30px;'
        f'background:{c};transform:rotate({r}deg)"></div>'
        for x, y, c, r in [(-120, 380, COBALT, -18), (860, 330, GREEN, -8), (1010, 190, ORANGE, 12)]
    )
    return (
        f'<div style="position:relative;width:1200px;height:630px;overflow:hidden;background:{BG}">{cards}'
        f'<div style="position:absolute;inset:95px 200px 115px 200px;border-radius:44px;background:#FFF;'
        f"display:flex;flex-direction:column;align-items:center;justify-content:center;gap:44px;"
        f'box-shadow:0 20px 60px rgba(17,18,22,.12)">{body}</div></div>'
    )


def tile(fill: str, glyph: str, dashed: bool = False) -> str:
    edge = f"border:5px dashed {LINE};background:#FFF" if dashed else f"background:{fill}"
    return (
        f'<div style="width:92px;height:92px;box-sizing:border-box;border-radius:22px;{edge};display:flex;'
        f'align-items:center;justify-content:center"><svg viewBox="0 0 100 100" width="92" height="92">{glyph}</svg></div>'
    )


def avatar(fill: str, glyph: str, dashed: bool = False) -> str:
    edge = f"border:5px dashed {LINE};background:#FFF" if dashed else f"background:{fill}"
    return (
        f'<div style="width:104px;height:104px;box-sizing:border-box;border-radius:50%;{edge};display:flex;'
        f'align-items:center;justify-content:center;overflow:hidden"><svg viewBox="0 0 100 100" width="104" height="104">{glyph}</svg></div>'
    )


def row(items: list[str], gap: int) -> str:
    return f'<div style="display:flex;gap:{gap}px">{"".join(items)}</div>'


def play(g: dict[str, str]) -> str:
    """A friend's quiz: the sender's marks above, the friend's row still open."""
    marks = [(GREEN, TICK), (GREEN, TICK), (ORANGE, CROSS), (GREEN, TICK), (GREEN, TICK)]
    sent = row([tile(c, m) for c, m in marks], 18)
    mine = row([tile("", "", dashed=True) for _ in marks], 18)
    return frame(lockup(g, 84) + f'<div style="display:flex;flex-direction:column;gap:18px">{sent}{mine}</div>')


def join(g: dict[str, str]) -> str:
    """A game together: the host (the mascot), two players and a free seat."""
    host = f'<svg viewBox="21 16 158 178" x="14" y="12" width="72" height="80">{head(g)}</svg>'
    seats = [avatar(COBALT, host), avatar(PURPLE, PERSON), avatar(GREEN, PERSON), avatar("", PLUS, dashed=True)]
    return frame(lockup(g, 84) + row(seats, 28))


def write(html: str, name: str) -> None:
    out = WEB / name
    screenshot(html, out, 1200, 630)
    subprocess.run(["magick", str(out), "-strip", "-define", "png:compression-level=9", str(out)], check=True)
    print(f"wrote {out.relative_to(WEB.parents[2])} ({out.stat().st_size:,} bytes)")


if __name__ == "__main__":
    g = groups()
    write(play(g), "og-play.png")
    write(join(g), "og-join.png")
