"""Compare the live design catalog with the code (#188 — unified design system, track E).

Code is the source of truth; a value changed on the catalog page is a proposal
until it lands in the app. This script finds those proposals with a three-way
diff per token:

  base    the tokens the catalog was last generated from (its `meta.ref` commit)
  live    the catalog's tokens.json as it is now (read from the artifact)
  code    the tokens generated from the working tree

  live != base, code == base   -> proposal   (the founder changed it in the catalog)
  code != base, live == base   -> code       (the app changed; republish)
  both changed, live != code   -> conflict   (ask the founder, never pick)
  both changed, live == code   -> settled    (a proposal that already landed)

Usage:
  python3 -m scripts.design_catalog.sync --live <live tokens.json> --out <pending.json>
Prints a readable summary; writes the machine-readable report to --out.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

from .swift_tokens import THEME, build_tokens

FAMILIES = ("color", "spacing", "radius", "shadow")


def flatten(tokens: dict) -> dict[str, object]:
    """name -> comparable value; type styles as `type.<style>` -> (size, weight)."""
    flat: dict[str, object] = {}
    for fam in FAMILIES:
        for t in tokens.get(fam, {}).get("tokens", []):
            flat[t["name"]] = t["value"]
    for group in tokens.get("type", {}).get("groups", []):
        for s in group.get("styles", []):
            flat[f"type.{s['name']}"] = {"fontSize": s.get("fontSize"), "fontWeight": s.get("fontWeight")}
    return flat


def base_tokens(root: Path, ref: str) -> dict | None:
    """Tokens generated at the commit the catalog was built from, or None if unreachable."""
    sha = ref.rsplit("@", 1)[-1]
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        return None
    if subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True, check=False).returncode:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        wt = Path(tmp) / "base"
        subprocess.run(["git", "-C", str(root), "worktree", "add", "--detach", "-q", str(wt), sha], check=True)
        try:
            return build_tokens(wt)
        except (ValueError, FileNotFoundError):
            return None  # a commit whose Theme.swift predates the generator
        finally:
            subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(wt)], check=True)


BLOCKS = {"palette": "private enum Palette", "space": "enum Spacing", "radius": "enum Radius", "shadow": "enum Shadow"}


def swift_line(root: Path, name: str) -> int | None:
    """Line in Theme.swift that defines a token, for the agent applying a proposal."""
    lines = (root / THEME).read_text(encoding="utf-8").splitlines()
    prefix, _, rest = name.partition("-")
    if name.startswith("type."):
        header, ident = "extension Font", "hangs" + name[5:6].upper() + name[6:]
    elif prefix in BLOCKS and rest:
        header, ident = BLOCKS[prefix], rest
    else:
        header, ident = "enum Colors", name
    start = next((i for i, line in enumerate(lines) if header in line), None)
    if start is None:
        return None
    for i in range(start, len(lines)):
        if re.search(rf"static (let|var) {re.escape(ident)}\b", lines[i]):
            return i + 1
    return None


def classify(base: dict | None, live: dict, code: dict) -> list[dict]:
    rows = []
    for name in sorted(set(live) | set(code) | set(base or {})):
        b, lv, c = (base or {}).get(name), live.get(name), code.get(name)
        if lv == c:
            kind = "settled" if base is not None and lv != b else None
        elif base is None:
            kind = "differs"  # no base to tell who changed it: ask
        elif lv != b and c == b:
            kind = "proposal" if lv is not None else "removed-in-catalog"
            if b is None:
                kind = "added-in-catalog"
        elif c != b and lv == b:
            kind = "code"
        else:
            kind = "conflict"
        if kind:
            rows.append({"token": name, "kind": kind, "base": b, "catalog": lv, "code": c})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--live", type=Path, required=True, help="the catalog's current project/tokens.json")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    live_tokens = json.loads(args.live.read_text())
    ref = live_tokens.get("meta", {}).get("ref", "")
    base = base_tokens(args.root, ref)
    rows = classify(flatten(base) if base else None, flatten(live_tokens), flatten(build_tokens(args.root)))
    for r in rows:
        r["swiftLine"] = swift_line(args.root, r["token"])
    args.out.write_text(json.dumps({"ref": ref, "baseFound": base is not None, "rows": rows}, indent=1) + "\n")

    if base is None:
        print(f"base commit {ref or '(none)'} not reachable: differences are listed without telling who changed what")
    if not rows:
        print("catalog and code agree: nothing pending")
    for r in rows:
        print(f"{r['kind']:>18}  {r['token']}: catalog {json.dumps(r['catalog'])} · code {json.dumps(r['code'])}"
              + (f" · Theme.swift:{r['swiftLine']}" if r["swiftLine"] else ""))


if __name__ == "__main__":
    main()
