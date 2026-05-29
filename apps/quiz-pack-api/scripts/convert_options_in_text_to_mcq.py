"""Convert "options-in-question-text" questions to ``text_multichoice``.

Detects questions whose body embeds a comma/or-separated option list after a
colon (e.g. ``"How many bones does a baby have: fewer, the same, or more?"``)
and rewrites them into proper MCQ shape:

  - ``question``: prefix before the options-colon, with ``?`` appended.
  - ``type``: ``"text_multichoice"``.
  - ``possible_answers``: ``{"a": opt1, "b": opt2, ...}`` keyed by lowercase letter.
  - ``correct_answer``: the matched key letter (e.g. ``"c"``).
  - ``alternative_answers``: cleared (MCQ evaluator routes on key, not value).

Match is deterministic — ``correct_answer`` must align with exactly one option
(after normalising articles + punctuation, with substring fallback). Ambiguous
or unmatched questions are left untouched and surfaced in the change log so a
human can decide. Idempotent: questions already typed ``text_multichoice`` or
already carrying ``possible_answers`` are skipped.

Issue #42 task 42.11.
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

# Anchor at end-of-string. ``[^:?]`` excludes nested colons/question-marks so
# we always pick the LAST colon that precedes the terminal ``?``.
OPTIONS_TAIL_RE = re.compile(r":\s*(?P<list>[^:?]+?)\?\s*$")

KEYS: tuple[str, ...] = ("a", "b", "c", "d", "e", "f")
_ARTICLE_RE = re.compile(r"^(the|a|an)\s+", re.IGNORECASE)


_MAX_OPTION_CHARS = 60
_OPTION_REJECT_CHARS = (".", "—", "–")


def parse_options(raw: str) -> list[str] | None:
    """Split a tail like ``"X, Y, or Z"`` into ``["X", "Y", "Z"]``.

    Returns ``None`` if fewer than 2 options or any option is empty after
    trimming. Also returns ``None`` if any option exceeds ``_MAX_OPTION_CHARS``
    or contains sentence-terminator punctuation (``.``, em/en-dash) — those
    signal we've captured the wrong colon (e.g. ``"The challenge: write ...
    How many was the limit — 50, 100, or 200?"`` would otherwise produce one
    50-word "option" and two short ones).
    """
    s = raw.strip().rstrip("?").strip()
    if not s:
        return None
    # Collapse trailing ``", or "`` / ``" or "`` into a single comma so we can
    # split on commas uniformly.
    s = re.sub(r",?\s+or\s+", ", ", s, flags=re.IGNORECASE)
    parts = [p.strip().rstrip(",;:") for p in s.split(",")]
    parts = [p for p in parts if p]
    if len(parts) < 2:
        return None
    for p in parts:
        if len(p) > _MAX_OPTION_CHARS:
            return None
        if any(ch in p for ch in _OPTION_REJECT_CHARS):
            return None
    return parts


def _normalize(s: str) -> str:
    s = (s or "").lower().strip()
    s = _ARTICLE_RE.sub("", s)
    s = re.sub(r"[.!?,;:]+$", "", s).strip()
    s = re.sub(r"\s+", " ", s)
    return s


def _contains_as_word(haystack: str, needle: str) -> bool:
    """``needle in haystack`` with word boundaries on both sides.

    Pins out false positives like ``"1" in "216"`` (sequence-completion
    questions where the answer is a continuation, not one of the listed
    terms). ``\\b`` treats letter/digit transitions as boundaries, so
    multi-token needles with internal spaces still match correctly.
    """
    if not haystack or not needle:
        return False
    return bool(re.search(rf"\b{re.escape(needle)}\b", haystack))


def find_matching_option(
    answer: str,
    options: list[str],
    alternative_answers: list[str] | None = None,
) -> int | None:
    """Return the option index that matches ``answer``, or ``None``.

    Match priority: exact normalised equality > unique word-boundary
    substring containment (either direction). Tries ``correct_answer`` first,
    then ``alternative_answers`` one-by-one (alternatives let us catch
    ``"20 quadrillion ants"`` ↔ option ``"20 quadrillion"``).

    Word-boundary matching is load-bearing — naive substring would treat
    ``"216"`` as containing ``"1"`` and convert sequence-completion questions
    into MCQs whose listed terms are red herrings, not the actual answer.
    """
    norm_opts = [_normalize(o) for o in options]
    candidates = [answer] + list(alternative_answers or [])
    for cand in candidates:
        nc = _normalize(cand)
        if not nc:
            continue
        for i, no in enumerate(norm_opts):
            if no and no == nc:
                return i
        hits = [
            i
            for i, no in enumerate(norm_opts)
            if no and (_contains_as_word(nc, no) or _contains_as_word(no, nc))
        ]
        if len(hits) == 1:
            return hits[0]
    return None


def convert_question_inplace(q: dict[str, Any]) -> dict[str, Any] | None:
    """Mutate ``q`` in place. Return a change record, or ``None`` if untouched.

    Skips when:
      - question already typed ``text_multichoice`` (idempotency),
      - ``possible_answers`` already populated,
      - no options-tail regex match,
      - option count outside [2, 6] (defensive — keeps MCQ small),
      - ``correct_answer`` cannot be aligned to exactly one option.
    """
    qtype = (q.get("type") or "text").strip()
    if qtype == "text_multichoice":
        return None
    if q.get("possible_answers"):
        return None
    qtext = q.get("question") or ""
    if not isinstance(qtext, str):
        return None
    m = OPTIONS_TAIL_RE.search(qtext)
    if not m:
        return None
    options = parse_options(m.group("list"))
    if options is None or not (2 <= len(options) <= len(KEYS)):
        return None
    correct = q.get("correct_answer")
    if not isinstance(correct, str) or not correct.strip():
        return None
    alts_raw = q.get("alternative_answers") or []
    alts = [a for a in alts_raw if isinstance(a, str)]
    idx = find_matching_option(correct, options, alts)
    if idx is None:
        return None

    key = KEYS[idx]
    new_question = qtext[: m.start()].rstrip().rstrip(",;:")
    if not new_question:
        return None
    new_question = new_question + "?"
    possible_answers = {KEYS[i]: opt for i, opt in enumerate(options)}

    record = {
        "id": q.get("id"),
        "before_question": qtext,
        "before_answer": correct,
        "matched_option": options[idx],
        "key": key,
        "options": possible_answers,
    }
    q["question"] = new_question
    q["type"] = "text_multichoice"
    q["possible_answers"] = possible_answers
    q["correct_answer"] = key
    # Alt answers are a free-text-evaluator concept; the MCQ fast-path keys on
    # ``possible_answers`` membership, not on alt strings, so leaving them in
    # would be dead metadata.
    q["alternative_answers"] = []
    return record


def _questions_view(data: Any) -> list[dict[str, Any]] | None:
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        return data["questions"]
    if isinstance(data, list):
        return data
    return None


def process_file(path: Path, dry_run: bool = False) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    qs = _questions_view(data)
    if qs is None:
        return []
    changes: list[dict[str, Any]] = []
    for q in qs:
        if not isinstance(q, dict):
            continue
        rec = convert_question_inplace(q)
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
            print(f"{label}: converted {len(changes)}")
            for rec in changes:
                print(
                    f"  - {rec['id']}: key={rec['key']} "
                    f"option={rec['matched_option']!r}"
                )
    suffix = " (dry-run)" if args.dry_run else ""
    print(f"total converted: {total}{suffix}")


if __name__ == "__main__":
    main()
