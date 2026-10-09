"""Build the Trubbo design catalog (claude.ai Design System artifact) from code.

#188 — unified design system, track D. Code is the source of truth: this script
reads Theme.swift, the component sources, the component guide, the copy rules
and the committed component snapshots, and writes the artifact's `project/`
tree. The catalog is never edited by hand; proposals made on it are pending
changes until they land in the app (track E, /design-sync).

Usage:
  python3 -m scripts.design_catalog.build --out <dir> [--index-from <design-system.json>] [--blobs <snapshot-blobs.json>]
Snapshots are asset uploads. When some are not uploaded yet the script writes
<dir>/upload-needed.json and stops: upload those files to the artifact, record
the returned URLs with `--record-uploads <json {file name: url}>`, run again.
Then publish <dir> to the artifact with the batches the script prints.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from .components import GUIDE, collect, write_component
from .cover import cover_html
from .swift_tokens import APP, build_tokens

REPO = "michalkalis/quiz-agent"
COPY_RULES = Path("docs/design/copy-style.md")
BASELINE = Path("scripts/design-token-baseline.txt")
MAX_PATHS_PER_CALL = 250


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True).stdout.strip()


KEEP = {"proposal", "conflict", "added-in-catalog", "differs"}


def keep_proposals(tokens: dict, rows: list[dict]) -> list[dict]:
    """Leave the founder's undecided catalog values in place (code stays the truth
    for the app; the catalog must not silently drop a proposal). Returns the rows kept."""
    kept = []
    for r in rows:
        if r["kind"] not in KEEP or r["catalog"] is None:
            continue
        note = f" Waiting for the app: the catalog proposes {json.dumps(r['catalog'])}, the app has {json.dumps(r['code'])}."
        if r["token"].startswith("type."):
            for g in tokens["type"]["groups"]:
                for st in g["styles"]:
                    if st["name"] == r["token"][5:]:
                        st.update(r["catalog"])
                        st["usage"] = st.get("usage", "") + note
        else:
            fam = next((f for f in ("color", "spacing", "radius", "shadow") if any(t["name"] == r["token"] for t in tokens[f]["tokens"])), None)
            entry = {"name": r["token"], "value": r["catalog"], "usage": "Added in the catalog." + note}
            if fam is None:
                tokens["color" if isinstance(r["catalog"], dict) or str(r["catalog"]).startswith("#") else "spacing"]["tokens"].append(entry)
            else:
                t = next(t for t in tokens[fam]["tokens"] if t["name"] == r["token"])
                t["value"] = r["catalog"]
                t["usage"] = t.get("usage", "") + note
        kept.append(r)
    return kept


def pending_section(rows: list[dict], open_comments: int) -> str:
    waiting = [r for r in rows if r["kind"] in KEEP | {"removed-in-catalog"}]
    lines = ["## Waiting for the app", ""]
    if not waiting and not open_comments:
        return "\n".join(lines + ["Nothing: the catalog and the app agree.", ""])
    lines.append(f"{len(waiting)} proposed value{'s' * (len(waiting) != 1)} and {open_comments} open comment{'s' * (open_comments != 1)} are not in the app yet. They reach it through `/design-sync`, as a pull request with before and after pictures.")
    lines.append("")
    for r in waiting:
        what = "removed in the catalog" if r["kind"] == "removed-in-catalog" else f"catalog `{json.dumps(r['catalog'])}`, app `{json.dumps(r['code'])}`"
        lines.append(f"- `{r['token']}`: {what}" + (" (conflict: the app changed too)" if r["kind"] == "conflict" else ""))
    return "\n".join(lines + [""])


def readme(tokens: dict, components: list, root: Path, ref: str) -> str:
    names = {t["name"] for fam in ("color", "spacing", "radius", "shadow") for t in tokens[fam]["tokens"]}
    styles = {s["name"] for g in tokens["type"]["groups"] for s in g["styles"]}

    def tok(*ns: str) -> str:
        missing = [n for n in ns if n not in names | styles]
        if missing:
            raise ValueError(f"README names tokens that no longer exist: {missing}")
        return ", ".join(f"`{n}`" for n in ns)

    baseline = sum(int(line.rsplit("\t", 1)[1]) for line in (root / BASELINE).read_text().splitlines() if line and not line.startswith("#"))
    guide = (root / GUIDE).read_text(encoding="utf-8")
    unused = len(re.findall(r"`(\w+)`", guide.split("## Unused", 1)[1])) if "## Unused" in guide else 0
    frozen = sum(len(c.states) for c in components)
    return f"""Trubbo is hands-free voice trivia for the car, and for any group that plays out loud. Every screen is read at a glance, every action also works by voice, and the app ships dark-first.

This catalog is generated from the iOS code at `{ref}`: `Utilities/Theme.swift` (tokens), the component sources and their frozen snapshots. **The code is the source of truth.** A comment or an edited value here is a proposal: it is a pending change until it lands in the app through a pull request, after which this catalog is generated again.

## Color

- Page {tok("bg")}, cards {tok("bgCard")}, sheets {tok("bgSheet")}; a sheet never uses the page color.
- Text {tok("ink")}; secondary text {tok("muted")}; struck-through answers {tok("mutedFaint")}; text and icons on a colored fill {tok("textOnAccent")}.
- The one primary action of a screen: {tok("action")} with {tok("textOnAction")} (ink in light mode, paper in dark). Links and row values {tok("blue")}. The chosen option {tok("accentPrimary")}. Listening, reading, thinking {tok("live", "liveAccent")}.
- Verdicts: correct {tok("greenCheck", "greenCorrect")} with text {tok("successText")}; a wrong answer reads neutral {tok("wrong")}; failures {tok("error")}; warnings {tok("warning")}. Soft fills behind them {tok("actionSoft", "greenSoft", "errorSoft", "neutralSoft")}.
- Small text on a tinted chip uses {tok("actionText", "blueText")}, which keep 4.5:1 contrast in light mode.
- Lines {tok("hairline", "subtleBorder")}.
- `palette-*` entries are the base values the tokens above are built from. Views never use them directly.

## Type

Three bundled faces: Anton for display text and numbers, Inter for body and buttons, IBM Plex Mono for labels and counters. Use the named styles, `Font.hangs*` in code ({tok("displayMD", "button", "monoLabel")} and the rest); a raw font size in a view is a lint finding.

## Spacing, radius, shadow

- Spacing steps {tok("space-xxs", "space-xs", "space-sm", "space-md", "space-lg", "space-xl", "space-xxl")}.
- Radii by role: cards {tok("radius-card")}, inner cards {tok("radius-cardInner")}, primary buttons {tok("radius-cta")}, chips {tok("radius-chip")}.
- Shadows: cards {tok("shadow-card")}, primary buttons {tok("shadow-cta")}.

## Components

{len(components)} shared components with {frozen} states, each shown as the real SwiftUI rendering in the current theme and at the largest text size. Use them before building anything new; each card says what the screen provides.

## Iconography

SF Symbols (Apple system icons) throughout; there is no custom icon set. The brand mark is set in type.

## Known gaps

- {baseline} older hand-typed values remain in views (spacing off the scale, about 20 font sizes, a few radii). A CI lint blocks new ones and the count only goes down.
- Not frozen as snapshots: pressed states, open menus, the animated voice glows.
- {unused} unused components are left out of this catalog.
"""


def copy_section(root: Path) -> str:
    text = (root / COPY_RULES).read_text(encoding="utf-8")
    rules = text.split("## Rules", 1)[1].split("## Review procedure", 1)[0]
    return "# Copy\n\nHow every text a player sees or hears is written (sk, cs, en). Source: `docs/design/copy-style.md`.\n\n## Rules" + rules.rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--index-from", type=Path, help="the artifact's current design-system.json, to keep its keys")
    parser.add_argument("--by", default="Michal Kalis")
    parser.add_argument("--blobs", type=Path, help="snapshot sha256 -> /_blob/ URL map (the artifact's project/snapshot-blobs.json)")
    parser.add_argument("--record-uploads", type=Path, help="JSON {staged file name: upload URL} to merge into --blobs, then exit")
    parser.add_argument("--pending", type=Path, help="sync.py report: undecided catalog proposals stay in the catalog, listed as waiting")
    parser.add_argument("--open-comments", type=int, default=0, help="open comment threads on the catalog, for the waiting section")
    parser.add_argument("--check", action="store_true", help="CI: build everything except upload-dependent previews, publish nothing")
    args = parser.parse_args()
    root, out = args.root, args.out
    blobs: dict[str, str] = json.loads(args.blobs.read_text()) if args.blobs and args.blobs.exists() else {}

    if args.record_uploads:
        needed = json.loads((out / "upload-needed.json").read_text())["sha_by_file"]
        for name, url in json.loads(args.record_uploads.read_text()).items():
            if not re.fullmatch(r"/_blob/[0-9a-f]{32}", url):
                raise ValueError(f"not an upload URL for {name}: {url}")
            blobs[needed[name]] = url
        args.blobs.write_text(json.dumps(blobs, indent=1, sort_keys=True) + "\n")
        print(f"{len(blobs)} snapshot uploads recorded in {args.blobs}")
        return

    if (out / "project").exists():
        shutil.rmtree(out / "project")
    project = out / "project"
    project.mkdir(parents=True)

    sha = git(root, "rev-parse", "--short", "HEAD")
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    tokens = build_tokens(root)
    rows = json.loads(args.pending.read_text())["rows"] if args.pending else []
    kept = keep_proposals(tokens, rows)
    tokens["meta"] = {
        "source": "github",
        "repo": REPO,
        "ref": f"{branch}@{sha}",
        "paths": {"tokens": ["apps/ios-app/Hangs/Hangs/Utilities/Theme.swift"], "fonts": [f"{APP}/Fonts"], "docs": [str(GUIDE), str(COPY_RULES)]},
        "synced": now[:10],
    }
    components = collect(root)

    files = [project / "tokens.json"]
    (project / "tokens.json").write_text(json.dumps(tokens, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    (project / "README.md").write_text(
        readme(tokens, components, root, f"{branch}@{sha}") + "\n" + pending_section(rows, args.open_comments), encoding="utf-8"
    )
    (project / "copy.md").write_text(copy_section(root), encoding="utf-8")
    files += [project / "README.md", project / "copy.md"]
    (project / "fonts").mkdir()
    for font in tokens["type"]["fonts"]:
        dst = project / font["file"]
        if not dst.exists():
            shutil.copyfile(root / APP / "Fonts" / Path(font["file"]).name, dst)
            files.append(dst)
    missing: dict[str, Path] = {}
    if (out / "uploads").exists():
        shutil.rmtree(out / "uploads")
    for c in components:
        files += write_component(root, out, c, blobs, missing)
    if args.check:
        print(f"check: tokens, {len(components)} components and {sum(len(c.states) for c in components)} states build ({len(missing)} snapshot(s) would need upload)")
        return
    if missing:
        staged = sorted(missing.values())
        (out / "upload-needed.json").write_text(json.dumps({
            "batches": [[str(f.resolve()) for f in staged[i : i + 25]] for i in range(0, len(staged), 25)],
            "sha_by_file": {f.name: sha for sha, f in missing.items()},
        }, indent=1) + "\n")
        raise SystemExit(f"{len(missing)} snapshot(s) not uploaded yet: see {out / 'upload-needed.json'}")
    (project / "snapshot-blobs.json").write_text(json.dumps(blobs, indent=1, sort_keys=True) + "\n")
    files.append(project / "snapshot-blobs.json")
    # The page only runs previews live (on the catalog's origin, where uploads
    # load) when a bundle exists; without one it renders them in an isolated
    # frame that blocks every image. The previews need no code, so the bundle
    # is an empty namespace whose header lists the components in catalog order.
    header = {"format": 4, "namespace": "Trubbo", "components": [{"name": c.name} for c in components]}
    (project / "components/bundle.js").write_text(
        f"/* @ds-bundle: {json.dumps(header, separators=(',', ':'))} */\nwindow.Trubbo = {{}};\n", encoding="utf-8"
    )
    files.append(project / "components/bundle.js")
    cover = project / "components/Cover/preview.html"
    cover.parent.mkdir(parents=True)
    cover.write_text(cover_html(tokens), encoding="utf-8")
    files.append(cover)

    index = json.loads(args.index_from.read_text()) if args.index_from else {
        "v": 3, "layout": "files", "createdOnFiles": {"v": 1, "at": now}, "namespace": "Trubbo", "libraries": [],
        "sections": {}, "groups": [], "assetGroups": {}, "blobs": {}, "docs": {"readme": "project/README.md", "sections": []},
    }
    index["title"] = "Trubbo"
    index["lastChange"] = {"by": args.by, "at": now, "via": f"scripts/design_catalog · {REPO}@{sha}", "note": "Generated from code"}
    (project / "design-system.json").write_text(json.dumps(index, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")

    rel = [str(f.relative_to(out)) for f in files]
    batches = [rel[i : i + MAX_PATHS_PER_CALL] for i in range(0, len(rel), MAX_PATHS_PER_CALL)]
    plan = {"root": str(out.resolve()), "batches": batches, "index": "project/design-system.json"}
    (out / "publish-plan.json").write_text(json.dumps(plan, indent=1) + "\n", encoding="utf-8")
    print(f"{len(rel)} files + index in {len(batches)} batch(es); components {len(components)}, states {sum(len(c.states) for c in components)}, catalog proposals kept {len(kept)}")
    print(f"plan: {out / 'publish-plan.json'}")


if __name__ == "__main__":
    main()
