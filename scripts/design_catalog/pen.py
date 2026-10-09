"""Pen (pen.dev) variables ⇄ code tokens (#188 — unified design system, track F).

The .pen file is encrypted, so only the agent reads and writes it (Pen MCP).
This module converts between the two shapes:

  code_view(tokens)   the code tokens Pen carries, flattened like sync.flatten
  pen_view(variables) the Pen variables (GetVariables().variables), same shape
  payload(tokens)     the SetVariables payload that makes Pen match the code

Pen variables use the code token names (`bg`, `space-md`, `radius-card`,
`type-question-size` / `-weight`, `font-display`). Older Pen names stay as
aliases (`bg-page` -> `$bg`) so existing designs follow the code. Shadows and
the private palette are not carried: a Pen variable cannot hold a shadow, and
views never use the palette directly.

Usage:
  python3 -m scripts.design_catalog.pen --out <pen-variables.json> [--pending <pending.json>]
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from .swift_tokens import build_tokens

REF_VAR = "tokens-ref"  # string variable: the commit the Pen values were written from

# Pen-only helpers, never compared: no code token exists for them.
PEN_ONLY = {
    "radius-pill": "capsule corners; SwiftUI draws a Capsule shape, not a radius token",
    "warning-bg": "notice background; the app uses warning at 12 % inline (OrderPackSummaryStep), no token yet",
}

# Names designs used before track F, kept as aliases of the code token.
LEGACY = {
    "bg-page": "bg", "bg-card": "bgCard", "bg-elevated": "bgSheet",
    "text-primary": "ink", "text-secondary": "muted", "text-tertiary": "mutedFaint",
    "text-on-accent": "textOnAccent", "accent-pink": "action", "accent-primary": "accentPrimary",
    "accent-primary-soft": "accentPrimarySoft", "accent-teal": "liveAccent", "accent-blue": "blue",
    "border-standard": "subtleBorder", "border-subtle": "hairline", "success-text": "successText",
    "success": "greenCheck", "accent-green": "greenCheck", "accent-red": "error", "accent-amber": "warning",
}


def _px(value: str) -> int | float:
    n = float(value.removesuffix("px"))
    return int(n) if n.is_integer() else n


def _family(group_name: str) -> str:
    """'Display (Anton)' -> 'Anton'."""
    return group_name.partition("(")[2].rstrip(")").strip()


def code_view(tokens: dict) -> dict[str, object]:
    flat: dict[str, object] = {}
    for t in tokens.get("color", {}).get("tokens", []):
        if not t["name"].startswith("palette-"):
            flat[t["name"]] = {"light": t["value"]["light"].lower(), "dark": t["value"]["dark"].lower()}
    for fam in ("spacing", "radius"):
        for t in tokens.get(fam, {}).get("tokens", []):
            flat[t["name"]] = t["value"]
    for g in tokens.get("type", {}).get("groups", []):
        flat[f"font-{g['family']}"] = _family(g["name"])
        for s in g["styles"]:
            flat[f"type.{s['name']}"] = {"fontSize": s.get("fontSize"), "fontWeight": s.get("fontWeight")}
    return flat


def _color(value) -> dict:
    if not isinstance(value, list):
        return {"light": str(value).lower(), "dark": str(value).lower()}
    out = {}
    for entry in value:
        mode = (entry.get("theme") or {}).get("mode")
        for m in ([mode] if mode else ["light", "dark"]):
            out.setdefault(m, str(entry["value"]).lower())
    return out


def _is_alias(value) -> bool:
    values = value if isinstance(value, list) else [{"value": value}]
    return all(isinstance(e["value"], str) and e["value"].startswith("$") for e in values)


def pen_view(variables: dict) -> dict[str, object]:
    flat: dict[str, object] = {}
    types: dict[str, dict] = {}
    for name, d in variables.items():
        if name == REF_VAR or name in PEN_ONLY or _is_alias(d["value"]):
            continue
        value = d["value"]
        if d["type"] == "color":
            flat[name] = _color(value)
        elif name.startswith("type-") and name.endswith(("-size", "-weight")):
            style, _, part = name[5:].rpartition("-")
            key = "fontSize" if part == "size" else "fontWeight"
            types.setdefault(style, {"fontSize": None, "fontWeight": None})[key] = (
                f"{value}px" if part == "size" else int(value)
            )
        elif d["type"] == "number" and name.startswith(("space-", "radius-")):
            flat[name] = f"{value}px"
        else:
            flat[name] = value
    flat.update({f"type.{s}": v for s, v in types.items()})
    return flat


def payload(tokens: dict, ref: str, skip: set[str] = frozenset()) -> dict[str, dict]:
    """SetVariables input: code tokens under their own names, legacy aliases, the ref.
    Tokens in `skip` (undecided Pen proposals) are left out so Pen keeps its value."""
    out: dict[str, dict] = {}
    for name, value in code_view(tokens).items():
        if name in skip:
            continue
        if isinstance(value, dict) and "light" in value:
            out[name] = {"type": "color", "value": [
                {"value": value["light"], "theme": {"mode": "light"}},
                {"value": value["dark"], "theme": {"mode": "dark"}},
            ]}
        elif name.startswith("type."):
            out[f"type-{name[5:]}-size"] = {"type": "number", "value": _px(value["fontSize"])}
            out[f"type-{name[5:]}-weight"] = {"type": "string", "value": str(value["fontWeight"])}
        elif name.startswith("font-"):
            out[name] = {"type": "string", "value": value}
        else:
            out[name] = {"type": "number", "value": _px(value)}
    for old, new in LEGACY.items():
        if new not in skip and old not in skip:
            out[old] = {"type": "color", "value": f"${new}"}
    out[REF_VAR] = {"type": "string", "value": ref}
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--pending", type=Path, help="sync --pen report; undecided Pen proposals are kept in Pen")
    args = parser.parse_args()

    def git(*a: str) -> str:
        return subprocess.run(["git", "-C", str(args.root), *a], capture_output=True, text=True, check=True).stdout.strip()

    ref = f"{git('rev-parse', '--abbrev-ref', 'HEAD')}@{git('rev-parse', '--short', 'HEAD')}"
    keep = {"proposal", "conflict", "added-in-pen", "differs"}
    rows = json.loads(args.pending.read_text())["rows"] if args.pending else []
    skip = {r["token"] for r in rows if r["kind"] in keep}
    data = payload(build_tokens(args.root), ref, skip)
    args.out.write_text(json.dumps(data, indent=1) + "\n")
    print(f"{len(data)} Pen variables from {ref} -> {args.out}" + (f" (kept {len(skip)} undecided in Pen)" if skip else ""))


if __name__ == "__main__":
    main()
