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
from typing import Any, Sequence

# Ensure `app.*` imports resolve when invoked as `python scripts/generate_pack.py`
# from the apps/quiz-pack-api/ working dir.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR not in sys.path:
    sys.path.insert(0, _APP_DIR)

from app.db.models import GenerationOrder
from app.orchestrator import OrderContext, PackGenerator, ProgressSink
from app.orchestrator.pack_generator import Stage
from app.orchestrator.stages import (
    DedupStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    VerificationStage,
)
from quiz_shared.database.question_store import QuestionStore
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
    """`QuestionStore` that owns nothing and finds no duplicates.

    `DedupStage` only calls `find_duplicates`; the rest of the protocol is
    untouched in this code path. Returning ``[]`` is safe for a one-shot
    CLI run — the user is generating a fresh pack, not deduping against an
    existing corpus.
    """

    def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]:
        return []

    # Protocol satisfaction — these are never invoked through the CLI path
    # (DedupStage only calls `find_duplicates`), so they raise to fail loud
    # if a future stage starts using them by accident.

    def add(self, question: Question) -> bool:  # pragma: no cover
        raise NotImplementedError("CLI dry-run does not persist to a question store")

    def upsert(self, question: Question) -> bool:  # pragma: no cover
        raise NotImplementedError("CLI dry-run does not persist to a question store")

    def get(self, question_id: str):  # pragma: no cover
        return None

    def delete(self, question_id: str) -> bool:  # pragma: no cover
        return False

    def search(self, *args, **kwargs):  # pragma: no cover
        return []

    def count(self, filters=None) -> int:  # pragma: no cover
        return 0

    def get_all(self, limit: int = 1000):  # pragma: no cover
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


def _build_dedup_store(name: str) -> QuestionStore:
    """Select the corpus `DedupStage` checks against.

    ``noop`` (default) finds no duplicates — correct for a one-shot fresh
    pack with no existing corpus. ``pgvector`` dedups against the live
    Postgres corpus (requires ``DATABASE_URL``), so the 0.85 cosine guard
    fires against real history (issue #42 task 42.27, was deferred 42.19c).
    """
    if name == "pgvector":
        from app.db.engine import normalize_async_url
        from quiz_shared.database.pgvector_client import PgvectorQuestionStore
        from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore

        url = os.environ.get("DATABASE_URL")
        if not url:
            raise SystemExit(
                "--dedup-store pgvector requires DATABASE_URL (Postgres + pgvector)."
            )
        return SyncPgvectorStore(
            PgvectorQuestionStore(database_url=normalize_async_url(url))
        )
    return _NoopQuestionStore()


def _build_stages(*, persist: bool, dedup_store: QuestionStore) -> list[Stage]:
    """Construct the standard pipeline. Persist is omitted in dry-run mode."""
    from app import feature_flags
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.scoring.multi_model_scorer import MultiModelScorer
    from app.sourcing.fact_sourcer import FactSourcer
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

    stages: list[Stage] = [
        SourcingStage(FactSourcer()),
        GenerationStage(generator),
        VerificationStage(FactVerifier()),
        ScoringStage(MultiModelScorer()),
        DedupStage(dedup_store, gold_standard_path=None),
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

    pack = await pack_generator.run(order)
    ctx = pack_generator.last_ctx
    questions = list(ctx.questions) if ctx else []

    pack_id = str(pack.id) if pack is not None else f"dry-run:{order.id}"
    print()
    print(f"pack_id: {pack_id}")
    print(f"questions: {len(questions)}")
    print(f"cost_cents: {ctx.cost_cents if ctx else 0}")
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
    parser.add_argument("--prompt", required=True, help="User-facing pack prompt")
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
