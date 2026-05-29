"""Auto-fix em-dash / explanation-tail in `correct_answer` (Issue #42 task 42.2).

For questions where `correct_answer` smushes a short canonical value with an
explanatory tail (delimited by em-dash, en-dash, " because ", or " namely "),
deterministically split:

  - Head (cleaned, stripped of trailing punctuation) becomes the new
    `correct_answer`.
  - Tail is appended to `explanation` (preserving any existing text).

Idempotent: after a fix the head no longer contains the delimiter, and the
appended tail is detected via substring check before re-appending.

Mutates JSON files in-place unless ``--dry-run`` is passed. Files are written
with the same indentation/encoding shape `answer_quality_audit.py` expects.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
GENERATED_DIR = REPO_ROOT / "data" / "generated"
PROD_EXPORTS = [
    REPO_ROOT / "apps" / "quiz-agent" / "questions_export.json",
    REPO_ROOT / "questions_export.json",
]

# Split delimiters: em/en dash with optional surrounding whitespace, or the
# words "because" / "namely" preceded by optional comma + whitespace. We use
# ``re.search`` so we pick the first such delimiter in the answer.
SPLIT_RE = re.compile(
    r"\s*[—–]\s*"  # em (U+2014) or en (U+2013) dash
    r"|\s*,?\s+because\s+"
    r"|\s*,?\s+namely\s+",
    re.IGNORECASE,
)


def split_answer(ans: str) -> tuple[str, str] | None:
    """Return (head, tail) if a delimiter splits the answer; else None.

    Returns ``None`` when no delimiter is found or when either side would be
    empty after stripping (so an orphan dash like ``"— foo"`` is a no-op).
    """
    if not ans:
        return None
    m = SPLIT_RE.search(ans)
    if not m:
        return None
    head = ans[: m.start()].strip().rstrip(",;:")
    tail = ans[m.end() :].strip()
    if not head or not tail:
        return None
    if tail[0].islower():
        tail = tail[0].upper() + tail[1:]
    if tail[-1] not in ".!?":
        tail = tail + "."
    return head, tail


def merge_explanation(existing: str | None, addition: str) -> str:
    """Append ``addition`` to ``existing`` unless it is already a substring.

    Idempotency hook: re-running the fixer on a question already fixed must
    not duplicate the tail in the explanation field.
    """
    if not existing:
        return addition
    if addition in existing:
        return existing
    sep = "" if existing.endswith((" ", "\n")) else " "
    return existing + sep + addition


def fix_question_inplace(q: dict[str, Any]) -> dict[str, Any] | None:
    """Mutate ``q`` in place. Return a change record, or None if untouched."""
    ans = q.get("correct_answer")
    if not isinstance(ans, str):
        return None
    split = split_answer(ans)
    if split is None:
        return None
    head, tail = split
    before = q["correct_answer"]
    q["correct_answer"] = head
    q["explanation"] = merge_explanation(q.get("explanation"), tail)
    return {"id": q.get("id"), "before": before, "after": head}


def _questions_view(data: Any) -> list[dict[str, Any]] | None:
    """Return the mutable list of question dicts in `data`, or None."""
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        return data["questions"]
    if isinstance(data, list):
        return data
    return None


def process_file(path: Path, dry_run: bool = False) -> list[dict[str, Any]]:
    """Apply fixes to one JSON file; return list of change records."""
    data = json.loads(path.read_text())
    qs = _questions_view(data)
    if qs is None:
        return []
    changes: list[dict[str, Any]] = []
    for q in qs:
        if not isinstance(q, dict):
            continue
        rec = fix_question_inplace(q)
        if rec is not None:
            rec["file"] = str(path)
            changes.append(rec)
    if changes and not dry_run:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return changes


def collect_files() -> list[Path]:
    files = sorted(GENERATED_DIR.glob("*.json"))
    for p in PROD_EXPORTS:
        if p.exists():
            files.append(p)
    return files


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="Report only.")
    ap.add_argument(
        "--path",
        type=Path,
        action="append",
        help="Specific file(s); defaults to data/generated/*.json + prod exports.",
    )
    args = ap.parse_args()

    files = args.path or collect_files()
    total = 0
    for fp in files:
        changes = process_file(fp, dry_run=args.dry_run)
        if changes:
            total += len(changes)
            try:
                label = str(fp.relative_to(REPO_ROOT))
            except ValueError:
                label = str(fp)
            print(f"{label}: fixed {len(changes)}")
    suffix = " (dry-run)" if args.dry_run else ""
    print(f"total fixed: {total}{suffix}")


if __name__ == "__main__":
    main()
