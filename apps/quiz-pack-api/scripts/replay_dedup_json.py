#!/usr/bin/env python3
"""Replay saved candidates through `DedupStage` — zero generation (#170 170.14b).

Sessions J and K need to re-measure a dedup decision over the SAME candidates
with different switches (strictness profile, QA branch, gray-zone judge)
without paying for a single generation call. This harness loads a JSON list
of `Question` dicts (a `generate_pack.py --out` file), composes `DedupStage`
from the #170 env flags exactly as the corpus CLI does, runs it once and
writes every per-candidate decision (kept/dropped, reason, nearest corpus
pair + score) next to the input.

Nothing is written to the database, ever: `--dry-run` is accepted for
symmetry with `generate_pack.py` but the harness has no write path at all.

``--dedup-store noop`` is REFUSED: with no corpus the run measures only
in-batch duplicates, which is not the decision anyone wants to replay.

One command (from apps/quiz-pack-api/, DATABASE_URL set — prod via
``fly proxy 15432:5432 -a quiz-pack-db`` is read-only for this script)::

    DEDUP_STRICTNESS_PER_CATEGORY="entertainment=cosine:0.92,cap:6" \\
    DEDUP_GRAYZONE_JUDGE=0 uv run --no-sync python scripts/replay_dedup_json.py \\
        --json-path docs/testing/runs/167-entertainment-pilot/pilot_167_r2.json \\
        --dedup-store pgvector --dry-run

Env flags read (all default OFF, see `app.feature_flags`):
DEDUP_STRICTNESS_PER_CATEGORY · ANSWER_CAP · DEDUP_QA_EMBEDDING ·
DEDUP_GRAYZONE_JUDGE · GRAYZONE_JUDGE_MAX_CALLS.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import feature_flags
from app.orchestrator.context import OrderContext
from app.orchestrator.stages.dedup import AsyncDuplicateFinder, DedupStage
from app.orchestrator.stages.grayzone_judge import (
    DEFAULT_MAX_CALLS,
    GrayZoneJudge,
)
from app.orchestrator.stages.strictness import (
    Strictness,
    parse_strictness,
)
from quiz_shared.models.question import Question

logger = logging.getLogger("replay_dedup_json")

FLAG_ENV_NAMES = (
    "DEDUP_STRICTNESS_PER_CATEGORY",
    "ANSWER_CAP",
    "DEDUP_QA_EMBEDDING",
    "DEDUP_GRAYZONE_JUDGE",
    "GRAYZONE_JUDGE_MAX_CALLS",
)


class _NullSink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        return None

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        return None


def build_grayzone_judge() -> GrayZoneJudge | None:
    """#170 D7 — the judge from env, deliberately NOT gated by the session-mode
    judge cut (`generate_pack._judges_enabled`): it is a dedup verdict, not a
    quality judge, and is allowed on the subscription."""
    if not feature_flags.dedup_grayzone_judge():
        return None
    max_calls = feature_flags.grayzone_judge_max_calls()
    return GrayZoneJudge(
        max_calls=max_calls if max_calls is not None else DEFAULT_MAX_CALLS
    )


def build_strictness() -> Strictness:
    """#170 D6 — the per-category profile from env. `DedupStage` and
    `TopUpStage` must read the SAME object (the spent-fact filter mirrors the
    dedup content check), so both callers compose it here."""
    return Strictness(
        profiles=parse_strictness(feature_flags.dedup_strictness_per_category()),
        answer_cap=feature_flags.answer_cap(),
    )


def build_dedup_stage(
    store: AsyncDuplicateFinder,
    gold_standard_path: str | Path | None = None,
    strictness: Strictness | None = None,
) -> DedupStage:
    """Compose `DedupStage` from the #170 env flags — the one place the corpus
    CLI and this harness share, so a replay reproduces a run's switches."""
    strictness = strictness if strictness is not None else build_strictness()
    return DedupStage(
        store,
        gold_standard_path=gold_standard_path,
        strictness=strictness,
        answer_counter=store if strictness.answer_cap else None,  # type: ignore[arg-type]
        qa_embedding=feature_flags.dedup_qa_embedding(),
        grayzone_judge=build_grayzone_judge(),
    )


def _build_store(name: str) -> AsyncDuplicateFinder:
    if name != "pgvector":
        raise SystemExit(
            f"--dedup-store {name!r} is refused: a replay without the corpus "
            "measures only in-batch duplicates. Use --dedup-store pgvector "
            "with DATABASE_URL set."
        )
    from app.db.engine import normalize_async_url
    from quiz_shared.database.pgvector_client import PgvectorQuestionStore

    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("--dedup-store pgvector requires DATABASE_URL (Postgres + pgvector).")
    return PgvectorQuestionStore(database_url=normalize_async_url(url))


def _load_candidates(paths: list[Path]) -> list[Question]:
    questions: list[Question] = []
    for path in paths:
        for entry in json.loads(path.read_text(encoding="utf-8")):
            questions.append(Question.from_dict(entry))
    return questions


def _default_out(paths: list[Path]) -> Path:
    first = paths[0]
    return first.with_name(f"{first.stem}.dedup-replay.json")


async def replay(
    candidates: list[Question],
    store: AsyncDuplicateFinder,
    *,
    language: str = "en",
    gold_standard_path: str | Path | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Run `DedupStage` once over `candidates`; returns (stage info, decisions)."""
    stage = build_dedup_stage(store, gold_standard_path)
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="dedup replay",
        language=language,
        target_count=len(candidates),
    )
    ctx.questions = list(candidates)
    result = await stage.run(ctx, _NullSink())  # type: ignore[arg-type]
    return result.info, stage.last_decisions


async def _run(args: argparse.Namespace, store: AsyncDuplicateFinder | None = None) -> int:
    if args.dedup_store != "pgvector":
        _build_store(args.dedup_store)  # raises SystemExit — refused before any work
    paths = [Path(p) for p in args.json_path]
    missing = [p for p in paths if not p.exists()]
    if missing:
        logger.error("JSON file(s) not found: %s", ", ".join(str(p) for p in missing))
        return 1
    candidates = _load_candidates(paths)
    if not candidates:
        # A replay of nothing is a wrong input file, not a successful run
        # (DedupStage's empty-input short-circuit carries no reasons/judge
        # keys either) — refuse before opening a store or writing anything.
        raise SystemExit(
            f"no candidates in {', '.join(str(p) for p in paths)} — nothing to replay"
        )
    if store is None:
        store = _build_store(args.dedup_store)

    info, decisions = await replay(
        candidates, store, language=args.language, gold_standard_path=args.gold_standard
    )

    payload = {
        "input": [str(p) for p in paths],
        "candidates": len(candidates),
        "env": {name: os.environ.get(name) for name in FLAG_ENV_NAMES},
        "info": info,
        "decisions": decisions,
    }
    out = Path(args.out) if args.out else _default_out(paths)
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    print(
        f"Replayed {len(candidates)} candidate(s): kept={info['kept']} "
        f"dropped={info['dropped']} reasons={info['drop_reasons']} "
        f"judge_calls={info['grayzone_judge_calls']} -> {out}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Replay saved candidates through DedupStage (no generation).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--json-path", action="append", required=True,
                        help="JSON list of Question dicts (generate_pack.py --out). Repeatable.")
    parser.add_argument("--dedup-store", default="pgvector",
                        help="Corpus to dedup against. Only 'pgvector' is accepted; "
                             "'noop' is refused (it would measure in-batch only).")
    parser.add_argument("--out", default=None,
                        help="Results JSON (default: <first input>.dedup-replay.json).")
    parser.add_argument("--language", default="en", help="Order language for the context.")
    parser.add_argument("--gold-standard", default=None,
                        help="Optional gold_standard.json for the Jaccard branch (default: none, "
                             "as in generate_pack.py).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Accepted for symmetry with generate_pack.py; this harness never "
                             "writes to the database in any mode.")
    return parser


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = build_parser().parse_args(argv)
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
