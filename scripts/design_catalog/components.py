"""Component cards for the design catalog (#188 — unified design system, track D).

Sources, all in the repo: the samples frozen by ComponentSnapshotTests (which
component, which states), their committed pixel baselines (the images), the
component guide `.claude/rules/ios-components.md` (group + when to use it) and
the component's own Swift source (its parameters). Nothing is typed in here.
"""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass, field
from pathlib import Path

TESTS = Path("apps/ios-app/Hangs/HangsTests")
SNAPSHOTS = TESTS / "__Snapshots__/ComponentSnapshotTests"
COMPONENTS_SRC = Path("apps/ios-app/Hangs/Hangs/Views/Components")
GUIDE = Path(".claude/rules/ios-components.md")
VARIANTS = ("light", "dark", "dark-xl")


@dataclass
class Component:
    name: str
    group: str
    use_for: str
    source: Path | None = None
    params: list[str] = field(default_factory=list)
    states: list[str] = field(default_factory=list)  # sample state names, in sample order
    sample_prefix: str = ""


def png_size(path: Path) -> tuple[int, int]:
    w, h = struct.unpack(">II", path.read_bytes()[16:24])
    return w, h


def read_guide(root: Path) -> dict[str, Component]:
    comps: dict[str, Component] = {}
    group = ""
    for line in (root / GUIDE).read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            group = line[3:].strip()
        m = re.match(r"\|\s*((?:`\w+`,?\s*)+)\|\s*(.+?)\s*\|$", line)
        if m and group and not group.startswith("Unused"):
            for name in re.findall(r"`(\w+)`", m.group(1)):
                comps[name] = Component(name=name, group=group, use_for=m.group(2))
    if not comps:
        raise ValueError(f"no components parsed from {GUIDE}")
    return comps


def read_samples(root: Path) -> list[tuple[str, str, str]]:
    """(sample prefix, state, component type) in file order."""
    out = []
    for path in sorted((root / TESTS).glob("ComponentSamples+*.swift")):
        text = path.read_text(encoding="utf-8")
        for prefix, state, type_name in re.findall(r'ComponentSample\("(\w+)\.(\w+)"\)\s*\{\s*([A-Z]\w*)', text):
            out.append((prefix, state, type_name))
    if not out:
        raise ValueError("no ComponentSample entries found")
    return out


def read_params(root: Path, name: str) -> tuple[Path, list[str]]:
    for path in sorted((root / COMPONENTS_SRC).rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        m = re.search(rf"^struct {name}\b[^{{]*\{{", text, re.MULTILINE)
        if not m:
            continue
        params = []
        for line in text[m.end() :].splitlines():
            if re.match(r"\s{4}(var body|func |init\()", line) or line.startswith("}"):
                break
            p = re.match(r"\s{4}(@Binding |@ObservedObject |@ViewBuilder )?(let|var) (\w+): ([^=\n{]+?)(\s*=\s*([^\n]+))?$", line)
            if p and not re.match(r"\s{4}(private|@State|@Environment|@StateObject)", line):
                default = f" = {p.group(6).strip()}" if p.group(6) else ""
                params.append(f"{(p.group(1) or '')}{p.group(3)}: {p.group(4).strip()}{default}")
        return path.relative_to(root), params
    raise ValueError(f"source of component {name} not found under {COMPONENTS_SRC}")


def collect(root: Path) -> list[Component]:
    comps = read_guide(root)
    for prefix, state, type_name in read_samples(root):
        if type_name not in comps:
            raise ValueError(f"sample {prefix}.{state} renders {type_name}, which the component guide does not list")
        c = comps[type_name]
        if c.sample_prefix and c.sample_prefix != prefix:
            raise ValueError(f"{type_name} sampled under two prefixes: {c.sample_prefix}, {prefix}")
        c.sample_prefix = prefix
        c.states.append(state)
        for v in VARIANTS:
            if not (root / SNAPSHOTS / f"pixels-id.{prefix}-{state}-{v}.png").exists():
                raise FileNotFoundError(f"baseline missing for {prefix}.{state} ({v}); record ComponentSnapshotTests first")
    for c in comps.values():
        c.source, c.params = read_params(root, c.name)
    return list(comps.values())


def write_component(root: Path, out: Path, c: Component) -> list[Path]:
    """Write README, preview and snapshot files under out/project/components/<name>/."""
    folder = out / "project/components" / c.name
    (folder / "snapshots").mkdir(parents=True, exist_ok=True)
    states = ", ".join(c.states) if c.states else "none"
    readme = [
        f"{c.use_for}",
        "",
        f"**Source:** `{c.source}`",
        f"**States frozen as snapshots:** {states}." if c.states else "**No snapshot:** animated or menu-only, see the source.",
        "",
        "## What the screen provides",
        "",
        *([f"- `{p}`" for p in c.params] or ["- nothing, it is configured internally"]),
    ]
    (folder / "README.md").write_text("\n".join(readme) + "\n", encoding="utf-8")
    written = [folder / "README.md"]
    if not c.states:
        return written

    rows, height = [], 36
    for state in c.states:
        cells = []
        sizes = []
        for v in VARIANTS:
            src = root / SNAPSHOTS / f"pixels-id.{c.sample_prefix}-{state}-{v}.png"
            dst = folder / "snapshots" / f"{state}-{v}.png"
            dst.write_bytes(src.read_bytes())
            written.append(dst)
            w, h = png_size(src)
            sizes.append(h)
            cls = "xl" if v == "dark-xl" else v
            cells.append(f'<img class="shot {cls}" src="../../components/{c.name}/snapshots/{state}-{v}.png" width="{w}" height="{h}" alt="{c.name} {state} {v}">')
        height += max(sizes[0], sizes[2]) + 30
        rows.append(f'<div class="row"><p class="state">{state}</p><div class="pair"><div>{cells[0]}{cells[1]}</div><div>{cells[2]}</div></div></div>')
    preview = f"""<!-- @dsCard group="{c.group}" height={min(height, 4000)} width=860 subtitle="{len(c.states)} state{'s' * (len(c.states) != 1)}" -->
<div class="ds-shots">
<style>
.ds-shots{{background:var(--bg);color:var(--muted);font-family:var(--font-mono);font-size:11px;display:grid;gap:8px;padding:8px}}
.ds-shots .head,.ds-shots .pair{{display:grid;grid-template-columns:402px 402px;gap:24px;align-items:start}}
.ds-shots .state,.ds-shots .head p{{margin:0;text-transform:uppercase;letter-spacing:.06em}}
.ds-shots .shot{{display:block;max-width:100%;height:auto}}
.ds-shots .shot.dark{{display:none}}
[data-theme="dark"] .ds-shots .shot.light{{display:none}}
[data-theme="dark"] .ds-shots .shot.dark{{display:block}}
</style>
<div class="head"><p>Current theme</p><p>Largest text size (dark)</p></div>
{chr(10).join(rows)}
</div>
"""
    (folder / "preview.html").write_text(preview, encoding="utf-8")
    written.append(folder / "preview.html")
    return written
