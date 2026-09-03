"""Re-normalise an already-generated batch's inline-option defects offline.

Same repair `GenerationStage` now runs inline (`app.generation.inline_options`),
applied to a JSON array of `Question` dumps — the shape `generate_pack.py --out`
writes — so a batch generated before the fix can be fixed without regenerating
it. Prints the counts plus every before → after stem so a human can eyeball the
rewrites before publishing.

    uv run --no-sync python scripts/normalise_batch.py <in.json> --out <out.json>

Omit ``--out`` for a read-only report.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.generation.inline_options import Counts, normalise


def normalise_batch(questions: list[dict[str, Any]]) -> tuple[Counts, list[dict]]:
    """Apply the normaliser to raw question dicts; return counts + a changelog."""
    counts = Counts()
    changes: list[dict] = []
    for q in questions:
        if not isinstance(q, dict) or not isinstance(q.get("question"), str):
            continue
        result = normalise(
            q["question"],
            q.get("type"),
            q.get("correct_answer"),
            q.get("possible_answers"),
            q.get("alternative_answers"),
        )
        if result is None:
            continue
        if result.kind == "unmatched":
            counts.inline_options_unmatched += 1
            changes.append(
                {
                    "kind": "unmatched",
                    "before": q["question"],
                    "answer": q.get("correct_answer"),
                }
            )
            continue
        record = {"kind": result.kind, "before": q["question"], "after": result.question}
        q["question"] = result.question
        if result.kind == "to_mcq":
            q["type"] = "text_multichoice"
            q["possible_answers"] = result.possible_answers
            q["correct_answer"] = result.correct_answer
            # Alternatives phrase the old open answer; the MCQ path routes on
            # option membership, so they would be dead metadata.
            q["alternative_answers"] = []
            counts.inline_options_to_mcq += 1
            record["options"] = result.possible_answers
            record["answer"] = result.correct_answer
        else:
            # Conversions always rewrite the stem; counting them here too made
            # the two numbers overlap. This one means MCQs that already had
            # options and merely recited them.
            counts.stem_options_stripped += 1
        changes.append(record)
    return counts, changes


def _load(path: Path) -> tuple[Any, list[dict[str, Any]]]:
    data = json.loads(path.read_text())
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        return data, data["questions"]
    if isinstance(data, list):
        return data, data
    raise SystemExit(f"{path}: expected a JSON array of questions")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=Path, nargs="+", help="Batch JSON file(s).")
    ap.add_argument("--out", type=Path, help="Write the normalised batch here.")
    args = ap.parse_args()
    if args.out and len(args.path) > 1:
        raise SystemExit("--out takes a single input file")

    total = Counts()
    for path in args.path:
        data, questions = _load(path)
        counts, changes = normalise_batch(questions)
        total.inline_options_to_mcq += counts.inline_options_to_mcq
        total.stem_options_stripped += counts.stem_options_stripped
        total.inline_options_unmatched += counts.inline_options_unmatched
        if changes:
            print(f"\n== {path.name} ==")
        for change in changes:
            print(f"[{change['kind']}]")
            print(f"  before: {change['before']}")
            if change["kind"] == "unmatched":
                print(f"  answer: {change['answer']!r} matches no single option")
                continue
            print(f"  after : {change['after']}")
            if "options" in change:
                print(f"  options: {change['options']}")
                print(f"  answer : {change['answer']!r}")
        if args.out:
            args.out.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
            print(f"\nwrote {args.out}")

    print(f"\n{total.as_info()}")


if __name__ == "__main__":
    main()
