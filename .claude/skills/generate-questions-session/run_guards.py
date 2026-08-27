"""Run the prod deterministic guards over a session-generated question batch.

Part of the temporary /generate-questions-session skill. Reuses the actual
pipeline guard code (no reimplementation) so session-mode output passes the
same bar as the prod ScoringStage with JUDGE_GATE off.

Usage (cwd MUST be apps/quiz-pack-api so app.* imports resolve):
    python ../../.claude/skills/generate-questions-session/run_guards.py \
        input.json --out final.json --rejects rejects.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))

from app.scoring.craft_guards import (  # noqa: E402
    long_answer_reason,
    stem_leak_reason,
    tf_imbalance_excess,
    true_false_key,
    units_reason,
)
from app.scoring.multi_model_scorer import compute_distractor_quality  # noqa: E402

MIN_DISTRACTOR_QUALITY = 4  # app/orchestrator/stages/scoring.py


def guard_reasons(q: dict) -> list[str]:
    question = q.get("question", "")
    answer = q.get("correct_answer")
    options = q.get("possible_answers")
    checks = (
        stem_leak_reason(question, answer, options),
        long_answer_reason(answer, options),
        units_reason(question, answer, options),
    )
    reasons = [r for r in checks if r]
    dq = compute_distractor_quality(answer, options)
    if dq is not None and dq < MIN_DISTRACTOR_QUALITY:
        reasons.append(f"distractor_quality({dq}<{MIN_DISTRACTOR_QUALITY})")
    return reasons


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rejects", type=Path, required=True)
    args = parser.parse_args()

    questions = json.loads(args.input.read_text())
    passed, rejects = [], []
    for q in questions:
        reasons = guard_reasons(q)
        (rejects if reasons else passed).append({**q, "_guard_reasons": reasons} if reasons else q)

    # T/F balance is a batch-level property: prod resolves the excess set from the
    # full pre-drop batch (scoring.py), so build it from `questions`, not `passed`.
    tf_items = [
        (q["id"], key)
        for q in questions
        if (key := true_false_key(q.get("correct_answer"), q.get("possible_answers")))
    ]
    excess_ids = set(tf_imbalance_excess(tf_items))
    if excess_ids:
        still_passed = []
        for q in passed:
            if q["id"] in excess_ids:
                rejects.append({**q, "_guard_reasons": ["tf_imbalance_excess"]})
            else:
                still_passed.append(q)
        passed = still_passed

    args.out.write_text(json.dumps(passed, indent=2, ensure_ascii=False))
    args.rejects.write_text(json.dumps(rejects, indent=2, ensure_ascii=False))
    print(f"passed: {len(passed)}  rejected: {len(rejects)}")
    for r in rejects:
        print(f"  REJECT {r.get('id', '?')}: {', '.join(r['_guard_reasons'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
