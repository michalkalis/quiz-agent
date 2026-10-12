"""The catalog cover (components/Cover/preview.html): the logo as the app draws it.

#194 — font + logo change: the logo is a question mark whose dot is a wave of
four tilted category cards, beside the wordmark. Sources: the app icon
(`AppIcon.icon`: its ground colour and the SVG layers of the question mark and
the cards), the in-app crop of that artwork (`TrubboMark`) and the lockup's
proportions and font (`HangsBrandMark`). Every colour is a token found by value,
so a colour the tokens do not hold fails the build.
"""

from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from .swift_tokens import THEME
from .swift_type import APP, GROUPS, FontResolver, _block, _num

ICON = APP / "AppIcon.icon"
MARK = APP / "Views/Components/Hangs/TrubboMark.swift"
LOCKUP = APP / "Views/Components/Hangs/HangsChrome.swift"
HOOK = "question"  # the icon layer TrubboMark strokes in the text colour (the cards keep theirs)
NAME_PX = 104  # wordmark size on the cover; the lockup keeps its in-app proportions around it
ICON_PX = 224
ICON_CORNER = 22.37  # % of the side: the iOS app icon mask, drawn as a rounded rect


@dataclass
class Brand:
    word: str
    mark_ratio: float  # mark height / wordmark size
    gap_ratio: float  # HStack spacing / wordmark size, at the default size
    tracking_ratio: float  # tracking / wordmark size
    font_key: str  # tokens.json type family key
    font_weight: int
    crop: tuple[float, ...]  # TrubboMark's window on the icon's 100-unit grid: x, y, width, height
    ground: str  # icon background, hex
    layers: list[tuple[str, list[ET.Element]]]  # (icon layer name, shapes), bottom first


def _one(pattern: str, text: str, where: Path) -> re.Match:
    m = re.search(pattern, text)
    if not m:
        raise ValueError(f"{where.name} no longer has the shape the cover reads: {pattern}")
    return m


def read_brand(root: Path) -> Brand:
    icon = json.loads((root / ICON / "icon.json").read_text())
    if len(icon["groups"]) != 1:
        raise ValueError("AppIcon.icon has more than one layer group; the cover draws one")
    layers = []
    for layer in reversed(icon["groups"][0]["layers"]):  # Icon Composer lists the top layer first
        if layer.get("hidden"):
            continue
        svg = ET.parse(root / ICON / "Assets" / layer["image-name"]).getroot()
        if svg.get("viewBox") != "0 0 100 100":
            raise ValueError(f"{layer['image-name']}: the cover expects the icon's 100-unit grid")
        for el in svg.iter():
            el.tag = el.tag.rpartition("}")[2]
        layers.append((layer["name"], list(svg)))
    rgb = [float(c) for c in icon["fill"]["solid"].removeprefix("srgb:").split(",")[:3]]

    crop = _one(r"static let crop = CGRect\(x: ([\d.]+), y: ([\d.]+), width: ([\d.]+), height: ([\d.]+)\)", (root / MARK).read_text(encoding="utf-8"), MARK)
    lockup = _block((root / LOCKUP).read_text(encoding="utf-8"), "struct HangsBrandMark")
    size = _num(_one(r"var size: CGFloat = ([\d.]+)", lockup, LOCKUP).group(1))
    fn, weight = _one(r"\.font\(Theme\.Hangs\.Fonts\.(\w+)\(size, weight: \.(\w+)\)\)", lockup, LOCKUP).groups()
    font = FontResolver(root, (root / THEME).read_text(encoding="utf-8")).resolve(fn, size, weight)
    return Brand(
        word=_one(r'Text\(verbatim: "([^"]+)"\)', lockup, LOCKUP).group(1),
        mark_ratio=float(_one(r"TrubboMark\(height: size \* ([\d.]+)\)", lockup, LOCKUP).group(1)),
        gap_ratio=float(_one(r"HStack\(spacing: ([\d.]+)\)", lockup, LOCKUP).group(1)) / size,
        tracking_ratio=-float(_one(r"\.tracking\(-size \* ([\d.]+)\)", lockup, LOCKUP).group(1)),
        font_key=GROUPS[font.fn],
        font_weight=font.weight,
        crop=tuple(_num(v) for v in crop.groups()),
        ground="#" + "".join(f"{round(c * 255):02x}" for c in rgb),
        layers=layers,
    )


class _Paint:
    """Turns hex fills and strokes into classes bound to the token holding that value."""

    def __init__(self, tokens: dict):
        self.by_hex: dict[str, str] = {}
        for t in tokens["color"]["tokens"]:
            if isinstance(t["value"], str):  # palette entries: one value in both themes
                self.by_hex.setdefault(t["value"].lower(), t["name"])
        self.rules: dict[str, str] = {}

    def cls(self, prop: str, token: str) -> str:
        name = f"{prop[0]}-{token}"
        self.rules[name] = f".cover .{name}{{{prop}:var(--{token})}}"
        return name

    def token(self, hex_value: str) -> str:
        if hex_value.lower() not in self.by_hex:
            raise ValueError(f"the logo uses {hex_value}, which no palette token holds")
        return self.by_hex[hex_value.lower()]

    def svg(self, layers: list[tuple[str, list[ET.Element]]], hook_token: str | None = None) -> str:
        out = []
        for name, shapes in layers:
            for shape in shapes:
                shape = ET.fromstring(ET.tostring(shape))  # a copy: the icon and the lockup paint differently
                for el in shape.iter():
                    classes = []
                    for prop in ("fill", "stroke"):
                        if el.get(prop, "").startswith("#"):
                            value = el.attrib.pop(prop)
                            classes.append(self.cls(prop, hook_token if name == HOOK and hook_token else self.token(value)))
                    if classes:
                        el.set("class", " ".join(classes))
                out.append(ET.tostring(shape, encoding="unicode"))
        return "".join(out)


def cover_html(tokens: dict, brand: Brand) -> str:
    names = {t["name"] for t in tokens["color"]["tokens"]}
    missing = [n for n in ("bg", "ink", "muted") if n not in names]
    if missing:
        raise ValueError(f"cover uses tokens that no longer exist: {missing}")
    paint = _Paint(tokens)
    ground = paint.cls("fill", paint.token(brand.ground))
    icon = paint.svg(brand.layers)
    mark = paint.svg(brand.layers, hook_token="ink")
    mark_w = round(brand.mark_ratio * brand.crop[2] / brand.crop[3], 4)
    rules = "\n".join(sorted(paint.rules.values()))
    return f"""<!-- @dsCard height=288 -->
<div class="cover">
<style>
.cover{{position:relative;width:960px;height:288px;background:var(--bg);overflow:hidden}}
.cover .icon{{position:absolute;left:{960 - 48 - ICON_PX}px;top:{(288 - ICON_PX) // 2}px}}
.cover .name{{position:absolute;left:48px;bottom:56px;margin:0;display:flex;align-items:center;gap:{round(brand.gap_ratio, 4)}em;font-family:var(--font-{brand.font_key});font-size:{NAME_PX}px;font-weight:{brand.font_weight};line-height:normal;letter-spacing:{brand.tracking_ratio}em;color:var(--ink)}}
.cover .mark{{flex:none;width:{mark_w}em;height:{brand.mark_ratio}em}}
.cover .tag{{position:absolute;left:50px;bottom:28px;max-width:440px;margin:0;font-family:var(--font-body);font-size:14px;color:var(--muted)}}
{rules}
</style>
<svg class="icon" width="{ICON_PX}" height="{ICON_PX}" viewBox="0 0 100 100" aria-hidden="true">
<!-- block: the app icon, ground and layers from AppIcon.icon, each colour bound to the palette token that holds it
     pattern: the logo's own wave of four tilted cards; the lockup on the left is HangsBrandMark (TrubboMark + wordmark) at its in-app proportions -->
<rect class="{ground}" width="100" height="100" rx="{ICON_CORNER}"/>
{icon}
</svg>
<p class="name"><svg class="mark" viewBox="{' '.join(map(str, brand.crop))}" aria-hidden="true">{mark}</svg>{brand.word}</p>
<p class="tag">Hands-free trivia, read at a glance and played by voice.</p>
</div>
"""
