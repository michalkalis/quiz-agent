#!/usr/bin/env python3
"""Design-token lint for the iOS app (#188 track B).

`apps/ios-app/Hangs/Hangs/Utilities/Theme.swift` is the app's only token set.
Views take colors, font sizes, spacing and corner radii from it; a value typed
in at the call site is how the three parallel token sets grew before #188.

Flags, at call sites (literal numbers, not named constants):
  color    Color(hex:/red:/white:/light:/.sRGB…), UIColor(hex:/red:/white:),
           Color.red…, and system colors passed to color modifiers
           (`.foregroundStyle(.gray)`, `.fill(.black)`)
  font     .system(size: 13), .hangsBody(13) / .hangsDisplay / .hangsMono,
           .custom(…, size: 13)
  spacing  .padding(12), .padding(.top, 12), spacing: 12   (0 is fine)
  radius   cornerRadius: 12, .cornerRadius(12)              (0 is fine)

Allowed: token references (`Theme.Hangs.*`, `Font.hangs*` presets), a named
constant in the view's `private enum Metrics` (a real design input, see
ios-swiftui-layout.md), `.clear`, hierarchical styles (`.primary`,
`.secondary`), `#if DEBUG` regions and Views/Debug. Anything else needs a
reviewed `// design-token: <reason>` comment on the line or the line above.

Ratchet: values that predate the lint are listed in `design-token-baseline.txt`
(file · rule · value · count). The lint fails when a file gains a value the
baseline doesn't cover, and also when the baseline has slack (a value was
removed) so the count can only go down — rerun with `--update-baseline` then.
Off-scale values leave the baseline in the #188 normalisation step (founder
approves before/after screenshots), not by snapping them ad hoc.

Usage: scripts/lint-design-tokens.py [--root <repo>] [--report] [--update-baseline]
       exit 1 on any finding outside the baseline or a stale baseline;
       --report groups all findings (baseline included) by rule and value.
"""

from __future__ import annotations

import argparse
import importlib
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
_a11y = importlib.import_module("lint-a11y-ids")
strip_comments = _a11y.strip_comments
debug_regions = _a11y.debug_regions

APP = Path("apps/ios-app/Hangs/Hangs")
TOKEN_FILES = {Path("Utilities/Theme.swift"), Path("Utilities/Color+Theme.swift")}
SKIP_DIRS = {"Debug"}

NUM = r"(\d+(?:\.\d+)?)"
SYSTEM_COLOR = r"(red|green|blue|orange|yellow|pink|purple|gray|black|white|cyan|mint|teal|indigo|brown)"
COLOR_MODIFIER = r"(foregroundColor|foregroundStyle|fill|stroke|strokeBorder|tint|background|border|accentColor)"

RULES: list[tuple[str, re.Pattern[str]]] = [
    ("color", re.compile(r"(?<![\w.])Color\(\s*(hex|red|white|light|hue|\.sRGB|\.displayP3)\b")),
    ("color", re.compile(r"(?<![\w.])UIColor\(\s*(hex|red|white)\b")),
    ("color", re.compile(r"(?<![\w.])Color\." + SYSTEM_COLOR + r"\b")),
    ("color", re.compile(r"\." + COLOR_MODIFIER + r"\(\s*\." + SYSTEM_COLOR + r"\b")),
    ("color", re.compile(r"\bcolor:\s*\." + SYSTEM_COLOR + r"\b")),
    ("font", re.compile(r"\.system\(\s*size:\s*" + NUM)),
    ("font", re.compile(r"\.hangs(?:Body|Display|Mono)\(\s*" + NUM)),
    ("font", re.compile(r"\.custom\([^()\n]*size:\s*" + NUM)),
    ("spacing", re.compile(r"\.padding\(\s*(?:\.\w+\s*,\s*|\[[^\]\n]*\]\s*,\s*)?" + NUM + r"\s*\)")),
    ("spacing", re.compile(r"\bspacing:\s*" + NUM)),
    ("radius", re.compile(r"\bcornerRadius:\s*" + NUM)),
    ("radius", re.compile(r"\.cornerRadius\(\s*" + NUM)),
]
EXEMPT = re.compile(r"//\s*design-token:")
BASELINE = Path(__file__).resolve().parent / "design-token-baseline.txt"


def line_of(src: str, offset: int) -> int:
    return src.count("\n", 0, offset) + 1


def lint_file(path: Path, rel: Path) -> list[tuple[str, str, str]]:
    """Return (location, rule, matched text) per finding."""
    src = path.read_text(encoding="utf-8")
    code = strip_comments(src)
    lines = src.splitlines()
    debug = debug_regions(src)
    findings = []
    for rule, pattern in RULES:
        for m in pattern.finditer(code):
            if any(a <= m.start() < b for a, b in debug):
                continue
            number = next((g for g in m.groups() if g and re.fullmatch(NUM, g)), None)
            if number is not None and float(number) == 0:
                continue
            ln = line_of(code, m.start())
            if any(EXEMPT.search(lines[i - 1]) for i in (ln, ln - 1) if 0 < i <= len(lines)):
                continue
            findings.append((f"{rel}:{ln}", rule, re.sub(r"\s+", " ", m.group(0).strip())))
    return findings


def baseline_key(loc: str, rule: str, text: str) -> str:
    return "\t".join((loc.rsplit(":", 1)[0], rule, text))


def read_baseline() -> Counter[str]:
    counts: Counter[str] = Counter()
    if BASELINE.exists():
        for line in BASELINE.read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, _, n = line.rpartition("\t")
                counts[key] = int(n)
    return counts


def write_baseline(counts: Counter[str]) -> None:
    header = "# Pre-#188 hardcoded design values (file, rule, value, count). Only ever shrinks.\n"
    body = "".join(f"{key}\t{n}\n" for key, n in sorted(counts.items()))
    BASELINE.write_text(header + body, encoding="utf-8")


def swift_files(root: Path) -> list[Path]:
    base = root / APP
    return sorted(
        p
        for p in base.rglob("*.swift")
        if p.relative_to(base) not in TOKEN_FILES and not SKIP_DIRS & set(p.relative_to(base).parts)
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--report", action="store_true", help="group findings by rule and value")
    parser.add_argument("--update-baseline", action="store_true", help="rewrite the baseline to today's findings")
    args = parser.parse_args()

    findings = []
    for path in swift_files(args.root):
        findings += lint_file(path, path.relative_to(args.root))

    if args.report:
        by_rule = Counter(rule for _, rule, _ in findings)
        for rule, count in by_rule.most_common():
            print(f"== {rule}: {count}")
            values = Counter(re.sub(r"\s+", " ", text) for _, r, text in findings if r == rule)
            for text, n in values.most_common():
                print(f"  {n:3d}  {text}")
        return 1 if findings else 0

    current = Counter(baseline_key(*f) for f in findings)
    if args.update_baseline:
        write_baseline(current)
        print(f"baseline rewritten: {sum(current.values())} value(s)")
        return 0

    allowed = read_baseline()
    budget = allowed.copy()
    new = []
    for loc, rule, text in findings:
        key = baseline_key(loc, rule, text)
        if budget[key] > 0:
            budget[key] -= 1
        else:
            new.append((loc, rule, text))
    for loc, rule, text in new:
        print(f"{loc}: [{rule}] {text} — use a Theme.Hangs token or a named Metrics constant")
    stale = +budget
    if stale:
        print(f"\nBaseline has {sum(stale.values())} value(s) no longer in the code — good; "
              "lock it in: scripts/lint-design-tokens.py --update-baseline")
    if new:
        print(f"\n{len(new)} new hardcoded design value(s). See scripts/lint-design-tokens.py.")
    if new or stale:
        return 1
    print(f"design-token lint: 0 new values ({sum(allowed.values())} pre-#188 values left in the baseline)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
