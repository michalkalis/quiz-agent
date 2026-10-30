#!/usr/bin/env python3
"""Interface-language guard (founder 2026-10-30: the whole app speaks the quiz language).

SwiftUI `Text` follows the app root's `\\.locale`, but text built in code cannot:
`String(localized: "…")` reads the phone's language unless it is told otherwise.
Every such call in the app target therefore passes
`bundle: .interface, locale: .interface` (see `Utilities/InterfaceLanguage.swift`).
One call without them shows an English (or phone-language) line inside a Slovak
screen, which is the bug this rule exists for.

A call whose first argument is not a string literal (a `LocalizedStringResource`
that already carries its locale) is not checked.

Usage: scripts/lint-interface-language.py [--root <repo>]   exit 1 on any finding.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CALL = re.compile(r"String\(\s*localized:\s*")
REQUIRED = ("bundle: .interface", "locale: .interface")


def call_end(src: str, open_paren: int) -> int:
    """Index just past the `)` matching `src[open_paren]`, skipping string literals."""
    depth = 0
    i = open_paren
    in_string = False
    while i < len(src):
        c = src[i]
        if in_string:
            if c == "\\" and src[i + 1] == "(":
                # Interpolation: the parens inside count, its strings are skipped.
                i = call_end(src, i + 1)
                continue
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(src)


def findings(root: Path) -> list[str]:
    out = []
    for path in sorted((root / "apps/ios-app/Hangs/Hangs").rglob("*.swift")):
        src = path.read_text()
        for match in CALL.finditer(src):
            if src[match.end()] != '"':
                continue
            call = src[match.start() : call_end(src, match.start() + len("String"))]
            if all(token in call for token in REQUIRED):
                continue
            line = src.count("\n", 0, match.start()) + 1
            out.append(f"{path.relative_to(root)}:{line}: String(localized:) without {', '.join(REQUIRED)}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    found = findings(parser.parse_args().root)
    for line in found:
        print(line)
    if found:
        print(f"\n{len(found)} call(s) would ignore the quiz language; add {', '.join(REQUIRED)}.")
        return 1
    print("interface language: every String(localized:) follows the quiz language")
    return 0


if __name__ == "__main__":
    sys.exit(main())
