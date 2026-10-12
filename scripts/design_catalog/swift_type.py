"""Type tokens from `Theme.Hangs.Fonts` (#188 — unified design system; #194 — font + logo change).

The catalog shows what the app renders, not the argument a view passes: the
`Font.hangs*` presets are resolved through the same steps Theme.swift takes
(the display scale, the Rethink Sans cut per weight, the iOS text style per
size). Each step is read from Swift in one exact shape; a new shape fails the
build instead of publishing a guess. Family names and weights of the bundled
cuts come from the font files themselves.
"""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass
from pathlib import Path

APP = Path("apps/ios-app/Hangs/Hangs")
# What `.system(...)` renders on iOS. Apple's face: never bundled, so Theme.swift never names it.
SYSTEM_FAMILY = "SF Pro"
SYSTEM_STACK = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", system-ui, sans-serif'
# SwiftUI Font.Weight -> CSS weight (Apple's standard mapping).
FONT_WEIGHTS = {"ultraLight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500,
                "semibold": 600, "bold": 700, "heavy": 800, "black": 900}
# Theme.Hangs.Fonts function -> catalog group and the tokens.json family key it uses.
GROUPS = {"display": "display", "content": "display", "body": "body", "mono": "mono"}


def _num(s: str) -> int | float:
    n = float(s)
    return int(n) if n.is_integer() else n


def font_file_info(path: Path) -> tuple[str, int, str]:
    """(family, weight, PostScript name) from a TrueType file's `name` and `OS/2` tables."""
    b = path.read_bytes()
    count = struct.unpack(">H", b[4:6])[0]
    tables = {b[12 + 16 * i : 16 + 16 * i].decode("latin-1"): struct.unpack(">I", b[20 + 16 * i : 24 + 16 * i])[0] for i in range(count)}
    weight = struct.unpack(">H", b[tables["OS/2"] + 4 : tables["OS/2"] + 6])[0]
    off = tables["name"]
    n, strings = struct.unpack(">HH", b[off + 2 : off + 6])
    names: dict[int, str] = {}
    for i in range(n):
        platform, _, lang, nid, length, o = struct.unpack(">HHHHHH", b[off + 6 + 12 * i : off + 18 + 12 * i])
        if platform == 3 and lang == 0x409:
            names[nid] = b[off + strings + o : off + strings + o + length].decode("utf-16-be")
    return names.get(16) or names[1], weight, names[6]  # 16 = typographic family, set on static cuts of a variable font


def _block(src: str, header: str) -> str:
    """Body of the first `<header> {` block, braces balanced."""
    start = src.index(header)
    i = src.index("{", start) + 1
    depth, j = 1, i
    while depth:
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        j += 1
    return src[i : j - 1]


def _one(pattern: str, text: str, what: str) -> re.Match:
    m = re.search(pattern, text)
    if not m:
        raise ValueError(f"Theme.Hangs.Fonts: {what} no longer has the shape the catalog reads")
    return m


def _switch(body: str, ret: str, what: str) -> list[tuple[float, tuple[str, ...]]]:
    """`case ..<N: return <ret>` arms, then `default:` -> [(upper bound, captured groups)]."""
    arms = re.findall(r"case \.\.<([\d.]+): return " + ret, body)
    default = re.findall(r"default: return " + ret, body)
    if len(default) != 1 or len(arms) + 1 != body.count("return "):
        raise ValueError(f"Theme.Hangs.Fonts: {what} switch no longer has the shape the catalog reads")
    return [(float(a[0]), a[1:]) for a in arms] + [(float("inf"), default[0])]


@dataclass
class Resolved:
    fn: str  # Theme.Hangs.Fonts function the preset ends in
    family: str
    size: int | float
    weight: int
    text_style: str  # what the size scales with under Dynamic Type
    tabular: bool = False


class FontResolver:
    """Theme.Hangs.Fonts, read once, answering "what does fn(size, weight) render?"."""

    def __init__(self, root: Path, src: str):
        fonts = _block(src, "enum Fonts")
        styles = _switch(_block(fonts, "static func textStyle(for size: CGFloat)"), r"\.(\w+) // (\d+)", "textStyle(for:)")
        self.styles = [(b, name, _num(pt)) for b, (name, pt) in styles]
        self.display = [(b, _num(s), w, t) for b, (s, w, t) in _switch(
            _block(fonts, "static func display("), r"content\(([\d.]+), weight: \.(\w+), relativeTo: \.(\w+)\)", "display(_:)")]
        _one(r"private static func content\(_ size: CGFloat, weight: Font\.Weight, relativeTo style: Font\.TextStyle\) -> Font \{\s*"
             r"\.custom\(RethinkSans\.name\(for: weight\), size: size, relativeTo: style\)\s*\}", fonts, "content(_:weight:relativeTo:)")
        self.content_default = _one(r"static func content\(_ size: CGFloat, weight: Font\.Weight = \.(\w+)\) -> Font \{\s*"
                                    r"content\(size, weight: weight, relativeTo: textStyle\(for: size\)\)\s*\}", fonts, "content(_:weight:)").group(1)
        self.body_default = _one(r"static func body\(_ size: CGFloat, weight: Font\.Weight = \.(\w+)\) -> Font \{\s*"
                                 r"\.system\(textStyle\(for: size\), weight: weight\)\s*\}", fonts, "body(_:weight:)").group(1)
        m = _one(r"static func mono\(_ size: CGFloat, weight: Font\.Weight = \.(\w+)\) -> Font \{\s*\.system\(textStyle\(for: size\), "
                 r"weight: weight == \.(\w+) \? \.(\w+) : \.(\w+)\)(\.monospacedDigit\(\))?\s*\}", fonts, "mono(_:weight:)")
        self.mono_default, self.mono_if, self.mono_then, self.mono_else, self.mono_tabular = *m.groups()[:4], bool(m.group(5))

        cuts = _block(fonts, "enum RethinkSans")
        self.cut_names = re.findall(r'"([\w-]+)"', _one(r"static let all = \[(.*?)\]", cuts, "RethinkSans.all").group(1))
        self.cut_for: dict[str, str] = {}
        for weights, name in re.findall(r'case ((?:\.\w+(?:, )?)+): return "([\w-]+)"', cuts):
            self.cut_for.update({w: name for w in re.findall(r"\.(\w+)", weights)})
        self.cut_default = _one(r'default: return "([\w-]+)"', cuts, "RethinkSans.name(for:)").group(1)
        self.fonts: dict[str, tuple[str, int]] = {}
        for name in self.cut_names:
            path = root / APP / "Fonts" / f"{name}.ttf"
            if not path.exists():
                raise FileNotFoundError(f"font file for {name} missing: {path}")
            family, weight, postscript = font_file_info(path)
            if postscript != name:
                raise ValueError(f"{path.name} is {postscript}, Theme.swift loads it as {name}")
            self.fonts[name] = (family, weight)
        if not set(self.cut_for.values()) | {self.cut_default} <= set(self.cut_names):
            raise ValueError("RethinkSans.name(for:) returns a cut that RethinkSans.all does not bundle")

    def text_style(self, size: float) -> tuple[str, int | float]:
        return next((name, pt) for bound, name, pt in self.styles if size < bound)

    def _cut(self, fn: str, size: float, weight: str, style: str) -> Resolved:
        family, w = self.fonts[self.cut_for.get(weight, self.cut_default)]
        return Resolved(fn, family, size, w, style)

    def resolve(self, fn: str, size: float, weight: str | None = None) -> Resolved:
        if fn == "display":  # the weight argument is ignored: the scale sets it
            _, s, w, style = next(arm for arm in self.display if size < arm[0])
            return self._cut(fn, s, w, style)
        if fn == "content":
            return self._cut(fn, size, weight or self.content_default, self.text_style(size)[0])
        style, pt = self.text_style(size)
        if fn == "body":
            return Resolved(fn, SYSTEM_FAMILY, pt, FONT_WEIGHTS[weight or self.body_default], style)
        if fn == "mono":
            w = self.mono_then if (weight or self.mono_default) == self.mono_if else self.mono_else
            return Resolved(fn, SYSTEM_FAMILY, pt, FONT_WEIGHTS[w], style, self.mono_tabular)
        raise ValueError(f"unknown Theme.Hangs.Fonts function {fn!r}")
