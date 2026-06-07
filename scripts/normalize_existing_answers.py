#!/usr/bin/env python3
"""Issue #46 task 46.A4 — one-off normalization pass over existing question data.

Reuses 46.A2's deterministic splitter (`_split_answer_head` /
`_violates_answer_brevity` from the quiz-pack-api GenerationStage) to repair
over-cap `correct_answer` values that have a clean short head before an
unambiguous tail marker (em/en-dash, "because", "while", …): the head stays in
`correct_answer`, the tail moves into `explanation` so nothing is lost. This is
exactly the same normalize-then-keep logic the live pipeline now applies, run
once over the historical corpus.

Scope (matches the task):
  - `data/generated/*.json`            (batch files: {"questions": [...]} )
  - `apps/quiz-agent/questions_export.json` (prod export: [ ... ] )

It does NOT call the LLM fallback (46.A2b): comma-tailed / genuinely open answers
have no deterministic short head, so they are left untouched and reported loudly
(CLAUDE.md rule #12) for Track B / a follow-up LLM pass to handle. Acceptance:
after the pass there are 0 over-cap answers with a *recoverable short head*.

Usage:
    python scripts/normalize_existing_answers.py            # apply + report
    python scripts/normalize_existing_answers.py --check    # report only, no writes
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

# Reuse A2's splitter from the live pipeline rather than re-implementing it.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "apps", "quiz-pack-api"))

from app.orchestrator.stages.generation import (  # noqa: E402
    _merge_explanation,
    _split_answer_head,
    _violates_answer_brevity,
)


def _data_files() -> list[str]:
    files = sorted(glob.glob(os.path.join(_REPO_ROOT, "data", "generated", "*.json")))
    files.append(os.path.join(_REPO_ROOT, "apps", "quiz-agent", "questions_export.json"))
    return files


def _load(path: str) -> tuple[dict | list, list[dict]]:
    """Return (document, questions-list). Handles both file shapes."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    questions = doc["questions"] if isinstance(doc, dict) else doc
    return doc, questions


def _apply_split(text: str, old_answer: str, head: str, tail: str) -> str:
    """Surgically rewrite one question's answer in the raw file text.

    A full ``json.dump`` round-trip reformats the hand-authored corpus (inline
    arrays expand to one-per-line), producing huge noise diffs. So we edit the
    raw text instead: replace just the `correct_answer` value and inject an
    `explanation` line right after it, preserving every other byte. The long
    over-cap answer is a unique string in the file, so the match is unambiguous
    — we assert that and fail loud otherwise.
    """
    needle = f'"correct_answer": {json.dumps(old_answer, ensure_ascii=False)}'
    count = text.count(needle)
    if count != 1:
        raise ValueError(
            f"expected exactly 1 match for {old_answer!r}, found {count} "
            "(ambiguous — aborting to avoid corrupting the file)"
        )
    pos = text.index(needle)
    line_start = text.rfind("\n", 0, pos) + 1
    indent = text[line_start:pos]  # leading whitespace before the key
    replacement = (
        f'"correct_answer": {json.dumps(head, ensure_ascii=False)},\n'
        f'{indent}"explanation": {json.dumps(tail, ensure_ascii=False)}'
    )
    return text.replace(needle, replacement, 1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check",
        action="store_true",
        help="report only; do not write any files",
    )
    args = ap.parse_args()

    total = violations = split = unsplittable = 0
    unsplittable_rows: list[tuple[str, str, str]] = []  # (file, reason, answer)

    for path in _data_files():
        rel = os.path.relpath(path, _REPO_ROOT)
        _doc, questions = _load(path)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        for q in questions:
            total += 1
            ca = q.get("correct_answer")
            reason = _violates_answer_brevity(ca)
            if reason is None:
                continue
            violations += 1
            head_tail = _split_answer_head(ca) if isinstance(ca, str) else None
            if head_tail is None:
                unsplittable += 1
                unsplittable_rows.append((rel, reason, str(ca)))
                continue
            head, tail = head_tail
            # All currently-splittable questions lack an `explanation` key
            # (verified for the corpus), so a fresh injection is correct; guard
            # against the unexpected case so we never silently clobber one.
            if q.get("explanation"):
                raise ValueError(
                    f"{rel}: question already has an explanation; merge path "
                    "not implemented for the one-off pass (fail loud, rule #12)"
                )
            text = _apply_split(text, ca, head, _merge_explanation(None, tail))
            split += 1
        if not args.check:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)

    mode = "DRY-RUN (--check)" if args.check else "APPLIED"
    print(f"=== 46.A4 normalization pass [{mode}] ===")
    print(f"files scanned       : {len(_data_files())}")
    print(f"questions scanned   : {total}")
    print(f"brevity violations  : {violations}")
    print(f"split (recovered)   : {split}")
    print(f"unsplittable (left) : {unsplittable}")

    if unsplittable_rows:
        # Fail loud: surface every answer we could not recover so a human /
        # Track B can route it (open-shape) or an LLM pass (46.A2b) can split it.
        print("\n--- UNSPLITTABLE over-cap answers (no deterministic short head) ---")
        for rel, reason, ca in unsplittable_rows:
            print(f"[{reason}] {rel}: {ca!r}")

    # Acceptance check: 0 over-cap answers with a *recoverable* short head must
    # remain. Re-audit the (now-written) corpus to prove it.
    remaining_recoverable = 0
    for path in _data_files():
        _doc, questions = _load(path)
        for q in questions:
            ca = q.get("correct_answer")
            if (
                _violates_answer_brevity(ca) is not None
                and isinstance(ca, str)
                and _split_answer_head(ca) is not None
            ):
                remaining_recoverable += 1

    print(f"\nremaining recoverable-head over-cap answers: {remaining_recoverable}")
    if remaining_recoverable and not args.check:
        print("FAIL: recoverable over-cap answers still present after the pass.")
        return 1
    print("OK" if not args.check else "OK (dry-run; re-run without --check to apply)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
