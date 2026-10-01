"""Read the app's one token file (Utilities/Theme.swift, #188 — unified design
system) into the Design System catalog's tokens.json shape.

Code is the source of truth: every value here is parsed from Swift, never typed
in. Anything the parser does not understand fails loudly, so a new token shape
in Theme.swift breaks the build instead of silently missing from the catalog.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

THEME = Path("apps/ios-app/Hangs/Hangs/Utilities/Theme.swift")
APP = Path("apps/ios-app/Hangs/Hangs")
FONT_WEIGHTS = {"regular": 400, "medium": 500, "semibold": 600, "bold": 700, "black": 900}


@dataclass
class Rgba:
    r: int
    g: int
    b: int
    a: float = 1.0

    def opacity(self, k: float) -> Rgba:
        return Rgba(self.r, self.g, self.b, self.a * k)

    def css(self) -> str:
        base = f"#{self.r:02x}{self.g:02x}{self.b:02x}"
        return base if self.a >= 0.999 else base + f"{round(self.a * 255):02x}"


def _hex(h: str) -> Rgba:
    h = h.lstrip("#")
    return Rgba(int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def _block(src: str, header: str) -> str:
    """Body of the first `<header> {` block, braces balanced."""
    start = src.index(header)
    i = src.index("{", start) + 1
    depth = 1
    j = i
    while depth:
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        j += 1
    return src[i : j - 1]


def _statements(body: str) -> list[tuple[str, str, str]]:
    """(name, expression, usage) per `static let`: `///` docs above plus the trailing `//` comment."""
    out: list[tuple[str, str, str]] = []
    doc: list[str] = []
    current: list[str] | None = None

    def is_open() -> bool:
        return current is not None and current[1].count("(") > current[1].count(")")

    def flush() -> None:
        nonlocal current
        if current:
            out.append((current[0], current[1], current[2]))
        current = None

    for raw in body.splitlines():
        line = raw.strip()
        code, _, comment = line.partition("//")
        if line.startswith("static let "):
            flush()
            m = re.match(r"static let (\w+)(?:: [\w.]+)? = (.*)", code.strip())
            if not m:
                raise ValueError(f"unparsed token line: {line}")
            current = [m.group(1), m.group(2).strip(), " ".join(doc + [comment.strip()]).strip()]
            doc = []
        elif is_open():
            current[1] += code.strip()  # type: ignore[index]
        elif line.startswith("///"):
            flush()
            doc.append(line.lstrip("/").strip())
        elif line.startswith("//"):
            flush()  # section headers (`// MARK:`) and code notes are not token docs
            doc = []
        else:
            flush()
            doc = []
    flush()
    return out


class _ColorParser:
    """Tiny recursive-descent evaluator for the color expressions Theme.swift uses."""

    def __init__(self, palette: dict[str, Rgba], known: dict[str, dict[str, Rgba]]):
        self.palette, self.known = palette, known

    def parse(self, expr: str) -> dict[str, Rgba]:
        self.s, self.i = expr.replace(" ", ""), 0
        value = self._term()
        if self.i != len(self.s):
            raise ValueError(f"trailing input in color expression: {expr}")
        return value

    def _eat(self, token: str) -> bool:
        if self.s.startswith(token, self.i):
            self.i += len(token)
            return True
        return False

    def _number(self) -> float:
        m = re.match(r"\d+(?:\.\d+)?", self.s[self.i :])
        if not m:
            raise ValueError(f"number expected in {self.s}")
        self.i += m.end()
        return float(m.group(0))

    def _ident(self) -> str:
        m = re.match(r"\w+", self.s[self.i :])
        if not m:
            raise ValueError(f"identifier expected in {self.s}")
        self.i += m.end()
        return m.group(0)

    def _term(self) -> dict[str, Rgba]:
        if self._eat("Color(light:"):
            light = self._term()["light"]
            if not self._eat(",dark:"):
                raise ValueError(f"dark: expected in {self.s}")
            dark = self._term()["dark"]
            self._eat(")")
            value = {"light": light, "dark": dark}
        elif self._eat("Color(hex:Palette."):
            c = self.palette[self._ident()]
            self._eat(")")
            value = {"light": c, "dark": c}
        elif self._eat("Palette."):
            c = self.palette[self._ident()]
            value = {"light": c, "dark": c}
        elif self._eat("Color.white"):
            value = {"light": Rgba(255, 255, 255), "dark": Rgba(255, 255, 255)}
        else:
            name = self._ident()
            if name not in self.known:
                raise ValueError(f"unknown color reference {name!r}")
            value = dict(self.known[name])
        while self._eat(".opacity("):
            k = self._number()
            self._eat(")")
            value = {t: c.opacity(k) for t, c in value.items()}
        return value


def call_sites(root: Path, needle: str) -> int:
    # `(?!\()`: a preset like `.hangsBody` shares its name with the raw-size
    # helper `.hangsBody(14)`, which must not count as a use of the preset.
    pattern = re.compile(re.escape(needle) + r"\b(?!\()")
    return sum(
        len(pattern.findall(p.read_text(encoding="utf-8")))
        for p in (root / APP).rglob("*.swift")
        if p.relative_to(root / APP) != Path("Utilities/Theme.swift")
    )


def build_tokens(root: Path) -> dict:
    src = (root / THEME).read_text(encoding="utf-8")
    palette_hex = dict(re.findall(r'static let (\w+) = "(#[0-9A-Fa-f]{6})"', _block(src, "private enum Palette")))
    palette = {k: _hex(v) for k, v in palette_hex.items()}

    colors: dict[str, dict[str, Rgba]] = {}
    color_tokens = []
    parser = _ColorParser(palette, colors)
    for name, expr, doc in _statements(_block(src, "enum Colors")):
        value = parser.parse(expr)
        colors[name] = value
        used = call_sites(root, f"Theme.Hangs.Colors.{name}")
        usage = (doc.rstrip(".") + ". " if doc else "") + f"Used in {used} place{'s' * (used != 1)}."
        light, dark = value["light"].css(), value["dark"].css()
        color_tokens.append({"name": name, "value": {"light": light, "dark": dark}, "usage": usage})

    palette_users = Counter(re.findall(r"Palette\.(\w+)", _block(src, "extension Theme.Hangs")))
    palette_tokens = [
        {"name": f"palette-{k}", "value": v.lower(), "usage": f"Base value (not used by views directly); referenced {palette_users[k]}× by semantic tokens."}
        for k, v in palette_hex.items()
    ]

    def scale(enum: str, prefix: str) -> list[dict]:
        out = []
        for name, value in re.findall(r"static let (\w+): CGFloat = ([\d.]+)", _block(src, f"enum {enum}")):
            used = call_sites(root, f"Theme.Hangs.{enum}.{name}")
            out.append({"name": f"{prefix}-{name}", "value": f"{value}px", "usage": f"Theme.Hangs.{enum}.{name}; used in {used} place{'s' * (used != 1)}."})
        return out

    shadows = []
    for name, color, radius, y in re.findall(
        r"static let (\w+) = ShadowSpec\(color: (.+?), radius: ([\d.]+), y: ([\d.]+)\)", _block(src, "enum Shadow")
    ):
        c = parser.parse(color)["light"].css()
        used = call_sites(root, f"Theme.Hangs.Shadow.{name}")
        shadows.append({"name": f"shadow-{name}", "value": f"0 {y}px {radius}px {c}", "usage": f"Theme.Hangs.Shadow.{name}; used in {used} place{'s' * (used != 1)}."})

    return {
        "name": "Trubbo",
        "version": 1,
        "color": {"themes": [{"id": "light", "name": "Light"}, {"id": "dark", "name": "Dark"}], "tokens": color_tokens + palette_tokens},
        "type": build_type(root, src),
        "spacing": {"tokens": scale("Spacing", "space")},
        "radius": {"tokens": scale("Radius", "radius")},
        "shadow": {"tokens": shadows},
    }


def build_type(root: Path, src: str) -> dict:
    fonts_block = _block(src, "enum Fonts")
    files = sorted(set(re.findall(r'\.custom\("([\w-]+)"', fonts_block)))
    family_of = {"Anton": "Anton", "Inter": "Inter", "IBMPlexMono": "IBM Plex Mono"}
    weight_of = {"Regular": "400", "Medium": "500", "SemiBold": "600", "Bold": "700"}
    fonts = []
    for f in files:
        stem, _, weight = f.partition("-")
        if not (root / APP / "Fonts" / f"{f}.ttf").exists():
            raise FileNotFoundError(f"font file for {f} missing")
        fonts.append({"family": family_of[stem], "file": f"fonts/{f}.ttf", "weight": weight_of[weight], "style": "normal"})

    families = {
        "display": '"Anton", "Impact", sans-serif',
        "body": '"Inter", system-ui, sans-serif',
        "mono": '"IBM Plex Mono", ui-monospace, monospace',
    }
    groups: dict[str, list[dict]] = {"display": [], "mono": [], "body": []}
    presets = re.findall(r"static var hangs(\w+): Font \{ \.hangs(Display|Mono|Body)\(([\d.]+)(?:, weight: \.(\w+))?\) \}", src)
    defaults = {"Display": "regular", "Mono": "medium", "Body": "regular"}
    bundled = {fam: {int(f["weight"]) for f in fonts if f["family"] == name} for fam, name in (("Display", "Anton"), ("Body", "Inter"), ("Mono", "IBM Plex Mono"))}
    for name, role, size, weight in presets:
        asked = FONT_WEIGHTS[weight or defaults[role]] if role != "Display" else 400
        # Theme.Hangs.Fonts falls back to Regular for a weight with no bundled
        # face; publish what the app renders and name the mismatch.
        w = asked if asked in bundled[role] else 400
        note = f" Asks for weight {asked}, which is not bundled, so it renders at 400." if w != asked else ""
        style = name[0].lower() + name[1:]
        used = call_sites(root, f".hangs{name}")
        groups[role.lower()].append(
            {"name": style, "fontSize": f"{size}px", "fontWeight": w, "usage": f"Font.hangs{name}; used in {used} place{'s' * (used != 1)}.{note}"}
        )
    if not presets:
        raise ValueError("no Font.hangs* presets found")
    return {
        "fonts": fonts,
        "families": families,
        "groups": [
            {"name": "Display (Anton)", "family": "display", "styles": groups["display"]},
            {"name": "Body (Inter)", "family": "body", "styles": groups["body"]},
            {"name": "Mono (IBM Plex Mono)", "family": "mono", "styles": groups["mono"]},
        ],
    }
