#!/usr/bin/env python3
"""Refresh the curated no-category topic pool with LLM-proposed candidates (#72 F-1).

Offline maintenance tool — NOT on the generation hot path. The no-category
("surprise me" / general-knowledge) path samples ``app/sourcing/topic_pool.json``
deterministically at runtime; this script is how that pool gets fresh blood.
Run it occasionally to grow/vary the pool: it asks ``TopicPlanner`` (the same
cheap model + cross-domain, no-military prompt) for candidate topics, merges the
genuinely-new ones into the JSON (case-insensitive dedupe), and writes it back.

New topics are appended at the end, so the change reads as a clean git diff you
review before committing — the LLM proposes, a human curates, the runtime stays
free of LLM calls.

Per memory ``feedback_qgen_import_cwd``: run from ``apps/quiz-pack-api/``. The
``PYTHONPATH=.`` prefix makes this app's local ``app`` package win over the
workspace's other editable ``app`` (apps/quiz-agent) on a standalone run.

Usage
-----
::

    cd apps/quiz-pack-api
    PYTHONPATH=. python scripts/refresh_topic_pool.py --count 20            # propose ~20, merge new
    PYTHONPATH=. python scripts/refresh_topic_pool.py --count 20 --dry-run  # show, don't write
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

# Ensure `app.*` imports resolve when invoked as `python scripts/refresh_topic_pool.py`
# from the apps/quiz-pack-api/ working dir (mirrors generate_pack.py).
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR not in sys.path:
    sys.path.insert(0, _APP_DIR)

from app.sourcing.topic_planner import TopicPlanner
from app.sourcing.topic_pool import POOL_PATH, TopicPool, merge_topics


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Refresh the curated topic pool.")
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        help="How many candidate topics to ask the LLM for (default: 20).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print proposed/new topics but do not write the pool file.",
    )
    return parser.parse_args(argv)


async def _run(args: argparse.Namespace) -> int:
    proposed = await TopicPlanner(topic_count=args.count).propose()
    if not proposed:
        print(
            "TopicPlanner returned no topics (model unavailable or empty output). "
            "Pool unchanged.",
            file=sys.stderr,
        )
        return 1

    existing = TopicPool().load()
    merged, added = merge_topics(existing, proposed)

    print(f"Proposed {len(proposed)} topics; {len(added)} are new.")
    for topic in added:
        print(f"  + {topic}")

    if not added:
        print("Nothing to add — pool already covers every proposed topic.")
        return 0

    if args.dry_run:
        print(f"\n[dry-run] {POOL_PATH} left unchanged.")
        return 0

    POOL_PATH.write_text(
        json.dumps({"topics": merged}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"\nWrote {len(merged)} topics to {POOL_PATH}.")
    return 0


def main(argv: list[str] | None = None) -> int:
    return asyncio.run(_run(_parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
