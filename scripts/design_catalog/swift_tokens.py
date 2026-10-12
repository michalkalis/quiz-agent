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

from .swift_type import (
    APP,
    FONT_WEIGHTS,
    GROUPS,
    SYSTEM_FAMILY,
    SYSTEM_STACK,
    FontResolver,
    _block,
    _num,
)

THEME = Path("apps/ios-app/Hangs/Hangs/Utilities/Theme.swift")


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
    """Type styles as the app renders them: every `Font.hangs*` preset resolved
    through Theme.Hangs.Fonts, grouped by the function it ends in."""
    fonts = FontResolver(root, src)
    font_ext = _block(src, "extension Font {")
    wrappers = {
        name: (fn, default if passes and not ignored else None, bool(passes and not ignored))
        for name, ignored, default, fn, passes in re.findall(
            r"static func hangs(\w+)\(_ size: CGFloat, weight( _)?: Font\.Weight = \.(\w+)\) -> Font \{\s*"
            r"Theme\.Hangs\.Fonts\.(\w+)\(size(, weight: weight)?\)\s*\}", font_ext)
    }
    declared = re.findall(r"static var hangs(\w+): Font \{", font_ext)
    presets = re.findall(
        r"static var hangs(\w+): Font \{ (\.hangs(\w+)|Theme\.Hangs\.Fonts\.(\w+))\(([\d.]+)(?:, weight: \.(\w+))?\) \}", font_ext)
    unread = sorted(set(declared) - {p[0] for p in presets})
    if not presets or unread:
        raise ValueError(f"Font.hangs* presets the catalog cannot read: {unread or 'none found'}")

    groups: dict[str, list[dict]] = {fn: [] for fn in GROUPS}
    group_family: dict[str, str] = {}
    for name, call, wrapper, direct, size, asked_weight in presets:
        if wrapper and wrapper not in wrappers:
            raise ValueError(f"Font.hangs{name} calls .hangs{wrapper}, which is not a Theme.Hangs.Fonts wrapper")
        fn, default, passes = wrappers[wrapper] if wrapper else (direct, None, True)
        weight = (asked_weight or default) if passes else None
        r = fonts.resolve(fn, _num(size), weight)
        source = f"{call}({size}" + (f", weight: .{asked_weight}" if asked_weight else "") + ")"
        rendered = f"{r.family} {r.weight} at {r.size} pt" + (" with tabular digits" if r.tabular else "")
        asks = [f"asks for {_num(size)}"] if r.size != _num(size) else []
        if asked_weight and passes and FONT_WEIGHTS[asked_weight] != r.weight:
            asks.append(f"asks for {asked_weight}")
        used = call_sites(root, f".hangs{name}")
        usage = f"Font.hangs{name} = `{source}`: {rendered}, scaling with .{r.text_style}"
        usage += (f" ({'; '.join(asks)})" if asks else "") + f". Used in {used} place{'s' * (used != 1)}."
        group_family[r.fn] = r.family
        groups[r.fn].append({"name": name[0].lower() + name[1:], "fontSize": f"{r.size}px", "fontWeight": r.weight, "usage": usage})

    families = {fam for fam, _ in fonts.fonts.values()}
    if len(families) != 1:
        raise ValueError(f"the bundled cuts are not one family: {sorted(families)}")
    face = families.pop()
    weights = {fn: sorted({s["fontWeight"] for s in styles}) for fn, styles in groups.items()}
    scale = " / ".join(str(s) for _, s, _, _ in fonts.display)
    notes = {
        "display": f"`Theme.Hangs.Fonts.display` snaps every size to the canvas scale {scale} pt, {face} {_w(weights['display'])}; "
                   "each step scales with an iOS text style (Dynamic Type).",
        "content": f"`Theme.Hangs.Fonts.content`: {face} at the size asked (answers, recaps, the wordmark), "
                   f"{fonts.content_default} unless a preset asks heavier, scaling with the nearest iOS text style.",
        "body": f"Controls in {SYSTEM_FAMILY}, the iOS system font, through text styles: a size snaps to the nearest style and follows "
                f"Dynamic Type. {SYSTEM_FAMILY} is not bundled, so previews here use your device's system UI font "
                "(SF on Apple devices, a fallback elsewhere).",
        "mono": f"Caps labels and counters in {SYSTEM_FAMILY} {_w(weights['mono'])}"
                f"{' with tabular digits, so counters do not jitter' if fonts.mono_tabular else ''}. Not bundled: previews use "
                "your device's system UI font" + (" and proportional digits." if fonts.mono_tabular else "."),
    }
    return {
        "fonts": [{"family": fam, "file": f"fonts/{name}.ttf", "weight": str(w), "style": "normal"} for name, (fam, w) in fonts.fonts.items()],
        "families": {"display": f'"{face}", system-ui, sans-serif', "body": SYSTEM_STACK, "mono": SYSTEM_STACK},
        "groups": [
            {"name": f"{fn.capitalize()} ({group_family[fn]})", "family": GROUPS[fn], "note": notes[fn], "styles": styles}
            for fn, styles in groups.items() if styles
        ],
    }


def _w(weights: list[int]) -> str:
    return " and ".join(map(str, weights))
