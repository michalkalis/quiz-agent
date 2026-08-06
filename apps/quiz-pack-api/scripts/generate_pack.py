#!/usr/bin/env python3
"""Thin-client CLI for `PackGenerator` (issue #36 task 2.16).

Wraps the same Phase-2 orchestrator the ARQ worker runs (`PackGenerator` +
the six stages in `app.orchestrator.stages`) behind a single entrypoint so
the `/generate-questions` skill, ad-hoc admin runs, and the e2e test fixture
all reach the pipeline through one path — no reimplemented sourcing /
critique / verification logic on the skill side (#32 §1.2 U1 keep-list).

Modes
-----
``--dry-run``  Skips ``PersistStage``: no Postgres / Redis required, no
               row writes. Real LLM clients are still constructed so
               respx-installed HTTP mocks (as used by the ``e2e_http_mocks``
               fixture in ``tests/integration/conftest.py``) drive the
               pipeline end-to-end. A synthetic ``pack_id`` is printed so
               the output shape matches a real run.

(default)      Live mode. Inserts an in-memory ``GenerationOrder`` into
               the database, runs the full 6-stage pipeline against real
               APIs, and persists the resulting pack. Requires
               ``DATABASE_URL`` + the provider keys the worker reads at
               startup. Not exercised in CI.

Per memory ``feedback_qgen_import_cwd``: run from ``apps/quiz-pack-api/``
so ``app.*`` and ``quiz_shared`` resolve from this repo's workspace setup.

Usage
-----
::

    cd apps/quiz-pack-api
    python scripts/generate_pack.py --prompt "famous capitals" --target-count 3 --dry-run
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Sequence

# Ensure `app.*` imports resolve when invoked as `python scripts/generate_pack.py`
# from the apps/quiz-pack-api/ working dir.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR not in sys.path:
    sys.path.insert(0, _APP_DIR)

from app import cost_tracking
from app.db.models import GenerationOrder
from app.orchestrator import PackGenerator, ProgressSink
from app.orchestrator.pack_generator import Stage
from app.orchestrator.stages import (
    DedupStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    TopUpStage,
    VerificationStage,
)
from app.orchestrator.stages.dedup import AsyncDuplicateFinder
from quiz_shared.models.question import Question

logger = logging.getLogger("generate_pack")


# Steering footer appended to the order prompt by `--mcq-bias` (issue #42
# task 42.19b). The order prompt never reaches the generation LLM (42.20
# BLOCKER root cause D) — the operative mechanism is the MCQ_EMPHASIS_MARKER
# this footer carries: `PackGenerator` detects it and sets
# `OrderContext.mcq_emphasis`, which travels through `GenerationStage` into
# `_format_mcq_patterns_section`'s hard quota. The footer text itself only
# informs sourcing / audit logs.
_MCQ_BIAS_INSTRUCTION = (
    "{marker}: at least 7 of every 10 questions in this "
    "batch MUST use one of these MCQ-routable reasoning patterns: "
    "{patterns} (true/false claims, odd-one-out sets, "
    "which-is-older/larger comparisons, year guesses). For this order "
    "those patterns are EXEMPT from the PATTERN DIVERSITY RULE's "
    "per-pattern cap — repeating them is expected and correct. "
    "Emit possible_answers for every question using one of those patterns."
)


def _mcq_bias_instruction() -> str:
    from app.generation.pattern_routing import MCQ_EMPHASIS_MARKER, PATTERNS_TO_MCQ

    return _MCQ_BIAS_INSTRUCTION.format(
        marker=MCQ_EMPHASIS_MARKER, patterns=", ".join(sorted(PATTERNS_TO_MCQ))
    )


# ---------------------------------------------------------------------------
# Sinks + stub stores for --dry-run (no Redis / no DB)
# ---------------------------------------------------------------------------


class _StdoutSink:
    """`ProgressSink` that prints one line per lifecycle event.

    The ARQ worker uses `DBProgressSink` (Postgres step_log + Redis pubsub).
    For the CLI we just want a visible breadcrumb so the operator sees
    the pipeline moving — no infra dependency.
    """

    def __init__(self) -> None:
        self._next_id = 0

    async def start_step(
        self, step: str, info: dict[str, Any] | None = None
    ) -> int:
        eid = self._next_id
        self._next_id += 1
        print(f"[{eid:02d}] start  {step}" + (f" {info}" if info else ""))
        return eid

    async def finish_step(
        self, step: str, event_id: int, info: dict[str, Any] | None = None
    ) -> None:
        print(f"[{event_id:02d}] finish {step}" + (f" {info}" if info else ""))

    async def publish(
        self,
        event_id: int,
        step: str,
        progress: int,
        info: dict[str, Any] | None = None,
    ) -> None:
        # `publish` is the live SSE event in production; on the CLI it is
        # redundant with `finish_step`, so we no-op to keep stdout legible.
        return None


class _NoopQuestionStore:
    """Duplicate finder that owns nothing and finds no duplicates.

    `DedupStage` only awaits `find_duplicates` (#150), so that is the whole
    surface. Returning ``[]`` is safe for a one-shot CLI run — the user is
    generating a fresh pack, not deduping against an existing corpus.
    """

    async def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]:
        return []


# ---------------------------------------------------------------------------
# Order + stage assembly
# ---------------------------------------------------------------------------


def _build_order(args: argparse.Namespace) -> GenerationOrder:
    """In-memory `GenerationOrder` — never inserted in dry-run mode."""
    prompt = args.prompt
    if args.mcq_bias:
        prompt = f"{prompt}\n\n{_mcq_bias_instruction()}"
    return GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"cli-{uuid.uuid4().hex[:12]}",
        product_id="pack_cli",
        prompt=prompt,
        category=args.category,
        theme=args.theme,
        target_count=args.target_count,
        language=args.language,
        status="in_progress",
    )


def _build_dedup_store(name: str) -> AsyncDuplicateFinder:
    """Select the corpus `DedupStage` checks against.

    ``noop`` (default) finds no duplicates — correct for a one-shot fresh
    pack with no existing corpus. ``pgvector`` dedups against the live
    Postgres corpus (requires ``DATABASE_URL``), so the 0.85 cosine guard
    fires against real history (issue #42 task 42.27, was deferred 42.19c).
    #150: the async store is handed to `DedupStage` directly — no sync bridge.
    """
    if name == "pgvector":
        from app.db.engine import normalize_async_url
        from quiz_shared.database.pgvector_client import PgvectorQuestionStore

        url = os.environ.get("DATABASE_URL")
        if not url:
            raise SystemExit(
                "--dedup-store pgvector requires DATABASE_URL (Postgres + pgvector)."
            )
        return PgvectorQuestionStore(database_url=normalize_async_url(url))
    return _NoopQuestionStore()


def _build_stages(*, persist: bool, dedup_store: AsyncDuplicateFinder) -> list[Stage]:
    """Construct the standard pipeline. Persist is omitted in dry-run mode."""
    from app import feature_flags
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.generation.expiry_classifier import ExpiryClassifier
    from app.scoring.multi_model_scorer import MultiModelScorer
    from app.sourcing.fact_sourcer import FactSourcer
    from app.sourcing.topic_pool import TopicPool
    from app.verification.fact_verifier import FactVerifier
    from quiz_shared.llm import factory as llm_factory

    # Lever A (issue #72 P1.1): source the gen/critique models from the dormant
    # feature flags, exactly as the API path's `_build_advanced_generator` does,
    # so `GENERATION_MODEL=claude-opus-4-8` actually reaches the generator on a
    # CLI run. With no env set the flags return None → the canonical
    # gpt-4o/gpt-4o-mini defaults (output unchanged). The Phase-6 validation run
    # goes through this path, so the model toggle MUST be honoured here.
    generator = AdvancedQuestionGenerator(
        generation_model=feature_flags.generation_model() or llm_factory.GEN,
        critique_model=feature_flags.critique_model() or llm_factory.CRITIQUE,
    )

    # Issue #76 F-3b — the founder's manual replenishment pass runs through
    # THIS path (decision B: no new command), so the expiry classifier must
    # be wired here exactly as in the worker (`worker.py on_startup`), behind
    # the same EXPIRY_CLASSIFICATION flag (default off → dormant, None).
    generation = GenerationStage(
        generator,
        expiry_classifier=(
            ExpiryClassifier() if feature_flags.expiry_classification() else None
        ),
    )
    verification = VerificationStage(FactVerifier())
    scoring = ScoringStage(MultiModelScorer())
    dedup = DedupStage(dedup_store, gold_standard_path=None)

    stages: list[Stage] = [
        # #72 F-1 (Scope A): the CLI/batch path wires the curated TopicPool so a
        # no-category run samples a diverse concrete topic set (no per-pack LLM
        # call). The worker/live path deliberately does NOT (stays byte-identical
        # until Scope B). Refresh the pool offline via scripts/refresh_topic_pool.py.
        SourcingStage(FactSourcer(), topic_pool=TopicPool()),
        generation,
        # 2026-08 perf fix: dedup runs right after generation, before
        # verification/scoring — a question dedup would discard anyway
        # should never pay for either, mirroring the worker's `_build_stages`.
        dedup,
        verification,
        scoring,
        # 2026-07-27 live-run F-b: the CLI omitted TopUpStage, so every pack
        # that lost questions downstream just delivered short (the plain run
        # needed 11 batches for 100 questions). Same instances as the initial
        # pass, mirroring the worker's `_build_stages` (#103 F5).
        TopUpStage(generation, verification, scoring, dedup),
    ]
    if persist:
        from app.db.session import AsyncSessionLocal

        stages.append(PersistStage(AsyncSessionLocal))
    return stages


def _write_out(questions: Sequence[Question], path: str) -> None:
    """Dump surviving questions to ``path`` as a reviewable JSON array.

    Every entry is a full ``Question.model_dump`` stamped
    ``review_status="pending_review"`` so dry-run batches land on disk in
    the same shape `Question.from_dict` reads back (42.20 review loop /
    42.23 importer).
    """
    payload = []
    for q in questions:
        entry = q.model_dump(mode="json")
        entry["review_status"] = "pending_review"
        payload.append(entry)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


# ---------------------------------------------------------------------------
# Run + report
# ---------------------------------------------------------------------------


async def _run(args: argparse.Namespace) -> int:
    persist = not args.dry_run
    order = _build_order(args)
    dedup_store = _build_dedup_store(args.dedup_store)
    stages = _build_stages(persist=persist, dedup_store=dedup_store)

    def _sink_factory(_order_id: str) -> ProgressSink:
        return _StdoutSink()  # type: ignore[return-value]

    pack_generator = PackGenerator(stages=stages, sink_factory=_sink_factory)

    if persist:
        from app.db.session import AsyncSessionLocal

        async with AsyncSessionLocal() as session:
            session.add(order)
            await session.commit()

    # 2026-07-27 live-run F-c: stage-summed cost_cents is structurally 0 on
    # the CLI (every stage returns cost_cents=0; only the worker drained the
    # cost tracker), so the printed cost and the order row were meaningless.
    # Mirror the worker's capture: Tavily calls report into the contextvar
    # tracker as they happen, OpenRouter account-usage snapshots bracket the
    # run (see app.cost_tracking for the shared-account caveat).
    tracker, tracker_token = cost_tracking.activate()
    usage_before = await cost_tracking.fetch_openrouter_usage()
    try:
        pack = await pack_generator.run(order)
    finally:
        cost_tracking.deactivate(tracker_token)
    usage_after = await cost_tracking.fetch_openrouter_usage()

    ctx = pack_generator.last_ctx
    questions = list(ctx.questions) if ctx else []

    llm_cost_usd: Decimal | None = None
    if usage_before is not None and usage_after is not None:
        llm_cost_usd = round(Decimal(str(max(usage_after - usage_before, 0.0))), 6)
    search_cost_cents = tracker.search_cost_cents
    stage_cost_cents = ctx.cost_cents if ctx else 0
    llm_cost_cents = int(round(llm_cost_usd * 100)) if llm_cost_usd is not None else 0
    cost_cents = stage_cost_cents + search_cost_cents + llm_cost_cents

    if persist and pack is not None:
        # Make the measured spend durable on the order row (the worker's
        # contract) and close the order out — a CLI order left `in_progress`
        # forever reads as a stuck order to the #103 sweep's operator.
        async with AsyncSessionLocal() as session:
            db_order = await session.get(GenerationOrder, order.id)
            if db_order is not None:
                db_order.status = "delivered"
                db_order.pack_id = pack.id
                db_order.delivered_at = datetime.now(timezone.utc)
                db_order.llm_cost_usd = llm_cost_usd
                db_order.search_cost_cents = search_cost_cents
                await session.commit()

    pack_id = str(pack.id) if pack is not None else f"dry-run:{order.id}"
    print()
    print(f"pack_id: {pack_id}")
    print(f"questions: {len(questions)}")
    print(f"cost_cents: {cost_cents}")
    print(f"  search (Tavily): {search_cost_cents}¢ ({tracker.tavily_credits} credits)")
    if llm_cost_usd is not None:
        print(f"  llm (OpenRouter delta): ${llm_cost_usd}")
    else:
        print(
            "  llm: UNMEASURED — OpenRouter usage snapshot unavailable "
            "(gateway not 'openrouter', key missing, or API failure)"
        )
    for i, q in enumerate(questions, start=1):
        source = q.source_url or "(no source)"
        print(f"  {i}. {q.question}  →  {q.correct_answer}   [{source}]")
    if args.out:
        _write_out(questions, args.out)
        print(f"out: wrote {len(questions)} questions to {args.out}")
    return 0


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="generate_pack",
        description="Thin-client CLI for the PackGenerator orchestrator.",
    )
    parser.add_argument(
        "--prompt",
        default="",
        help=(
            "User-facing pack prompt. Optional: omit (or pass a generic prompt "
            "like 'general knowledge') to trigger #72 F-1 no-category mode, "
            "where an LLM proposes a diverse concrete topic set for sourcing."
        ),
    )
    parser.add_argument("--language", default="en", help="ISO 639-1 language code")
    parser.add_argument(
        "--target-count",
        type=int,
        default=10,
        help="How many questions to generate (default: 10)",
    )
    parser.add_argument("--category", default=None, help="Optional category filter")
    parser.add_argument("--theme", default=None, help="Optional theme filter")
    parser.add_argument(
        "--out",
        default=None,
        help=(
            "After the run, dump surviving questions to this path as a JSON "
            "array (full Question dumps, review_status=pending_review)."
        ),
    )
    parser.add_argument(
        "--mcq-bias",
        action="store_true",
        help=(
            "Append a steering instruction to the order prompt nudging the "
            "LLM toward MCQ-routable patterns (PATTERNS_TO_MCQ)."
        ),
    )
    parser.add_argument(
        "--dedup-store",
        choices=["noop", "pgvector"],
        default="noop",
        help=(
            "Corpus the dedup stage checks against. 'noop' (default) finds no "
            "duplicates; 'pgvector' dedups against the live DATABASE_URL "
            "corpus so the 0.85 cosine guard fires against real history."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Skip the persist stage (no DB writes). Pipeline still runs; "
            "HTTP calls hit real providers unless respx mocks are installed."
        ),
    )
    return parser.parse_args(argv)


def cli_main(argv: Sequence[str] | None = None) -> int:
    """Entrypoint — importable so tests can drive the CLI in-process."""
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    args = _parse_args(argv)
    return asyncio.run(_run(args))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(cli_main())
