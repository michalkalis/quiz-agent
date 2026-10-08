#!/usr/bin/env python3
"""Stamp the #195 fresh-question boost onto dry-run JSON batches.

Reads one or more ``generate_pack --out`` files (a JSON list of ``Question``
dicts), runs the topicality classifier (``app.generation.topicality_classifier``)
in batches, and writes every question back to ``--out`` with ``boost_until``
set and the verdict (tier / event_date / rationale) under
``generation_metadata.extra.topicality`` — the same shape ``GenerationStage``
produces, so ``import_questions_json.py`` carries both into Postgres.

Prints a tier histogram and one ``tier | event_date | rationale | question``
line per question for review.

JSON mode only. Re-classifying the whole live corpus (a DB mode) is a later
step. Works under every gateway, incl. ``LLM_GATEWAY=session`` (Claude Code
subscription).

Usage (from ``apps/quiz-pack-api/``)::

    python scripts/classify_topicality.py \\
        --json-path data/batch-en.json --json-path data/batch-sk.json \\
        --out data/batch-boosted.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from app.generation.topicality_classifier import (  # noqa: E402
    TIERS,
    Topicality,
    TopicalityClassifier,
    apply_topicality,
)
from quiz_shared.llm import factory as llm_factory  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

DEFAULT_BATCH_SIZE = 25


async def classify_questions(
    questions: list[Question],
    classifier: TopicalityClassifier,
    batch_size: int = DEFAULT_BATCH_SIZE,
) -> list[Optional[Topicality]]:
    """Classify in batches and stamp each question in place; return verdicts."""
    now = datetime.now(timezone.utc)
    verdicts: list[Optional[Topicality]] = []
    for start in range(0, len(questions), batch_size):
        batch = questions[start : start + batch_size]
        results = await classifier.classify(batch, today=now.date())
        for q, t in zip(batch, results):
            if t is not None:
                apply_topicality(q, t, now)
        verdicts.extend(results)
    return verdicts


def _report(questions: list[Question], verdicts: list[Optional[Topicality]]) -> None:
    counts = Counter(t.tier if t else "unclassified" for t in verdicts)
    print("── tiers ─────────────────────────────")
    for tier in (*TIERS, "unclassified"):
        if counts.get(tier):
            print(f"  {tier:<13} {counts[tier]}")
    boosted = sum(1 for q in questions if q.boost_until is not None)
    print(f"  boosted now   {boosted}/{len(questions)}")
    print("── per question ──────────────────────")
    for q, t in zip(questions, verdicts):
        tier = t.tier if t else "unclassified"
        event = t.event_date.isoformat() if t and t.event_date else "-"
        why = t.rationale if t else "-"
        print(f"{tier} | {event} | {why} | {q.question}")


async def _run(args: argparse.Namespace) -> int:
    paths = [Path(p) for p in args.json_path]
    missing = [p for p in paths if not p.exists()]
    if missing:
        print(f"JSON file(s) not found: {', '.join(map(str, missing))}", file=sys.stderr)
        return 1
    questions = [
        Question.model_validate(raw)
        for path in paths
        for raw in json.loads(path.read_text())
    ]
    verdicts = await classify_questions(questions, TopicalityClassifier(), args.batch_size)
    _report(questions, verdicts)
    payload = [q.model_dump(mode="json") for q in questions]
    Path(args.out).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {len(payload)} question(s) to {args.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Stamp the #195 fresh-question boost onto JSON batches.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--json-path", action="append", required=True,
                        help="generate_pack --out JSON (list of Question dicts). Repeatable.")
    parser.add_argument("--out", required=True, help="Output JSON path.")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE,
                        help=f"Questions per classifier call (default {DEFAULT_BATCH_SIZE}).")
    args = parser.parse_args(argv)
    if llm_factory.gateway() == llm_factory.SESSION:
        # #169: fail loud on a logged-out CLI instead of an all-unclassified run.
        from quiz_shared.llm.session_cli import ensure_subscription_login

        ensure_subscription_login()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
