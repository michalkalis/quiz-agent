#!/usr/bin/env python3
"""Accessibility-identifier lint for the iOS app (#180 track E).

Two rules, both locale-safety (the UI ships in sk/cs/en, so visible text is
never a stable locator):

  1. App side — every interactive SwiftUI element under Hangs/Views (plus the
     project's button components) carries a `.accessibilityIdentifier(...)` in
     its own modifier chain, or sits inside a container whose chain has one
     (SwiftUI applies the identifier to the subtree).
  2. Test side — HangsUITests locate elements by identifier, never by visible
     label: every `app.<query>["..."]` literal must look like an identifier
     (`screen.element`, `screen-element`), not a sentence.

Exemptions are explicit and reviewed: a `// a11y-id: <reason>` comment on the
element's first line or the line above. Buttons inside `.alert` /
`.confirmationDialog` closures are exempt automatically (UIAlertController
ignores identifiers), as are `#if DEBUG` regions and Views/Debug (dev-only
tooling never under UI test).

Usage: scripts/lint-a11y-ids.py [--root <repo>]   exit 1 on any finding.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

APP_VIEWS = Path("apps/ios-app/Hangs/Hangs/Views")
UI_TESTS = Path("apps/ios-app/Hangs/HangsUITests")
SKIP_DIRS = {"Debug"}

# Project components that render a tappable control and leave the identifier
# to the call site (their definitions carry `// a11y-id: call-site`).
CUSTOM_INTERACTIVE = (
    "HangsPrimaryButton|HangsSecondaryButton|HangsGhostButton|HangsNavChip|"
    "HangsSourceLink|HangsToggleRow|HangsConfigRow"
)
INTERACTIVE = re.compile(
    r"(?<![\w.])(Button|NavigationLink|Toggle|Picker|TextField|SecureField|"
    r"TextEditor|Slider|Stepper|Menu|Link|ShareLink|DatePicker|"
    + CUSTOM_INTERACTIVE
    + r")\s*[({]"
    r"|\.(onTapGesture|onLongPressGesture)\b"
)
# Any `Head(` / `Head {` expression — used to find an enclosing container whose
# own chain carries the identifier (SwiftUI applies it to the whole subtree).
ANY_EXPRESSION = re.compile(r"(?<![\w.])[A-Z]\w*\s*[({]")
ALERT_LIKE = re.compile(r"\.(alert|confirmationDialog)\s*\(")
EXEMPT = re.compile(r"//\s*a11y-id:")
# `screen.element`, `screen-element`, optionally ending in an interpolation.
IDENTIFIER_LITERAL = re.compile(r"^[a-z][A-Za-z0-9]*([.\-]([A-Za-z0-9]+|\\\(.*\)))+$")
QUERY_LITERAL = re.compile(
    r"\.(buttons|staticTexts|textFields|secureTextFields|textViews|otherElements|"
    r"images|switches|cells|sheets|menuItems|links|toggles|pickers|scrollViews|"
    r"tables|collectionViews|navigationBars|searchFields|sliders|steppers|"
    r"segmentedControls|tabBars|toolbars|webViews|any)\[\"([^\"]*)\"\]"
)


def strip_comments(src: str) -> str:
    """Blank out comments and string literals, preserving offsets and newlines.

    Returns a same-length text where comment and string bodies are spaces, so
    brace matching and keyword search ignore them.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif c == '"':
            # string literal (handles \" and multi-line """ crudely enough)
            triple = src.startswith('"""', i)
            j = i + (3 if triple else 1)
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if triple and src.startswith('"""', j):
                    j += 3
                    break
                if not triple and src[j] == '"':
                    j += 1
                    break
                if not triple and src[j] == "\n":
                    break
                j += 1
            for k in range(i + 1, j - (3 if triple else 1)):
                if out[k] != "\n":
                    out[k] = "x"  # keep literal "non-empty"; content irrelevant
            i = j
        else:
            i += 1
    return "".join(out)


def debug_regions(src: str) -> list[tuple[int, int]]:
    """Offsets of `#if DEBUG` … `#else|#endif` regions."""
    regions: list[tuple[int, int]] = []
    stack: list[tuple[bool, int]] = []  # (is_debug, start)
    for m in re.finditer(r"^[ \t]*#(if|elseif|else|endif)\b(.*)$", src, re.MULTILINE):
        kind, rest = m.group(1), m.group(2)
        if kind == "if":
            stack.append(("DEBUG" in rest, m.start()))
        elif kind in ("else", "elseif"):
            if stack and stack[-1][0]:
                regions.append((stack[-1][1], m.start()))
                stack[-1] = (False, m.start())
        elif kind == "endif" and stack:
            is_debug, start = stack.pop()
            if is_debug:
                regions.append((start, m.end()))
    return regions


def match_bracket(text: str, i: int) -> int:
    """Return index just past the bracket that closes text[i] (one of ({[)."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    close = pairs[text[i]]
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c in pairs:
            depth += 1
        elif c in ")}]":
            depth -= 1
            if depth == 0 and c == close:
                return j + 1
        j += 1
    return n


def skip_ws(text: str, i: int) -> int:
    n = len(text)
    while i < n and text[i] in " \t\r\n":
        i += 1
    return i


def expression_extent(text: str, start: int) -> tuple[int, int]:
    """From an element start, return (end_of_call, end_of_modifier_chain)."""
    n = len(text)
    i = start
    # element head: identifier or `.modifier`
    m = re.match(r"\.?[A-Za-z_]\w*", text[i:])
    i += m.end() if m else 0
    i = skip_ws(text, i)
    # argument list and trailing closures (possibly labelled: `label: { }`)
    while i < n:
        if text[i] in "({":
            i = match_bracket(text, i)
            j = skip_ws(text, i)
            lbl = re.match(r"[A-Za-z_]\w*\s*:\s*\{", text[j:])
            if lbl:
                i = j + lbl.end() - 1
                continue
            if j < n and text[j] == "{":
                i = j
                continue
            break
        break
    call_end = i
    # modifier chain: `.name`, `.name(...)`, `.name(...) { }`, `.name { }`
    while True:
        j = skip_ws(text, i)
        m = re.match(r"\.[A-Za-z_]\w*", text[j:])
        if not m:
            break
        k = j + m.end()
        k2 = skip_ws(text, k)
        while k2 < n and text[k2] in "({":
            k = match_bracket(text, k2)
            k2 = skip_ws(text, k)
            lbl = re.match(r"[A-Za-z_]\w*\s*:\s*\{", text[k2:])
            if lbl:
                k2 = k2 + lbl.end() - 1
                continue
        i = k
    return call_end, i


def line_of(src: str, offset: int) -> int:
    return src.count("\n", 0, offset) + 1


def exempt_at(lines: list[str], line_no: int) -> bool:
    for ln in (line_no, line_no - 1):
        if 1 <= ln <= len(lines) and EXEMPT.search(lines[ln - 1]):
            return True
    return False


def lint_app_file(path: Path, rel: Path) -> list[str]:
    src = path.read_text(encoding="utf-8")
    lines = src.splitlines()
    text = strip_comments(src)
    skip: list[tuple[int, int]] = debug_regions(text)
    for m in ALERT_LIKE.finditer(text):
        # Only the alert's own arguments and trailing closures are exempt — the
        # modifiers that follow it on the same chain (.sheet, .toolbar, …) are
        # ordinary content and stay linted.
        alert_end, _ = expression_extent(text, m.start())
        skip.append((m.start(), alert_end))
    # Expressions whose own modifier chain carries an identifier: SwiftUI
    # applies it to the subtree, so a control inside their body — or a gesture
    # later in the same chain — is covered.
    covering: list[tuple[int, int, int]] = []
    for m in ANY_EXPRESSION.finditer(text):
        call_end, chain_end = expression_extent(text, m.start())
        if ".accessibilityIdentifier" in text[call_end:chain_end]:
            covering.append((m.start(), call_end, chain_end))
    findings = []
    for m in INTERACTIVE.finditer(text):
        s = m.start()
        if any(a <= s < b for a, b in skip):
            continue
        call_end, chain_end = expression_extent(text, s)
        if ".accessibilityIdentifier" in text[call_end:chain_end]:
            continue
        is_gesture = bool(m.group(2))
        if any(cs < s < (ce if is_gesture else be) for cs, be, ce in covering):
            continue
        line_no = line_of(text, s)
        if exempt_at(lines, line_no):
            continue
        kind = m.group(1) or m.group(2)
        findings.append(f"{rel}:{line_no}: {kind} without accessibilityIdentifier")
    return findings


def lint_test_file(path: Path, rel: Path) -> list[str]:
    findings = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for idx, raw in enumerate(lines, start=1):
        code = raw.split("//", 1)[0]
        for m in QUERY_LITERAL.finditer(code):
            literal = m.group(2)
            if IDENTIFIER_LITERAL.match(literal):
                continue
            if exempt_at(lines, idx):
                continue
            findings.append(
                f'{rel}:{idx}: locator by visible text "{literal}" — use an accessibilityIdentifier'
            )
    return findings


def swift_files(root: Path) -> list[Path]:
    return sorted(
        p
        for p in root.rglob("*.swift")
        if not (set(p.relative_to(root).parts) & SKIP_DIRS)
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path)
    args = ap.parse_args()
    root: Path = args.root
    findings: list[str] = []
    app_files = swift_files(root / APP_VIEWS)
    test_files = swift_files(root / UI_TESTS)
    if not app_files or not test_files:
        print("lint-a11y-ids: no Swift files found — wrong --root?", file=sys.stderr)
        return 2
    for p in app_files:
        findings += lint_app_file(p, p.relative_to(root))
    for p in test_files:
        findings += lint_test_file(p, p.relative_to(root))
    for f in findings:
        print(f)
    print(
        f"lint-a11y-ids: {len(findings)} finding(s) across "
        f"{len(app_files)} view files and {len(test_files)} UI-test files"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
