"""ARQ WorkerSettings for quiz-pack-api.

`on_startup` builds the heavy LLM-backed collaborators (FactSourcer,
AdvancedQuestionGenerator, FactVerifier, MultiModelScorer, QuestionStore)
once per worker process and stashes them on the ARQ ``ctx`` so every
``process_order`` call can wrap them as Stages without re-initialising
HTTP clients on each job. Issue #36 task 2.10 wired this seam.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict

from arq.connections import RedisSettings
from arq.cron import cron
from quiz_shared.paths import find_in_ancestors

from app.config import get_settings

from .sweep import sweep_stuck_orders
from .tasks import process_order

logger = logging.getLogger(__name__)

# Locate gold_standard.json by walking up from this file. Used by DedupStage's
# Jaccard check; a missing file means the check is a no-op (the stage handles
# `None` by skipping the gold-standard comparison). Walking up -- rather than a
# fixed `parents[N]` -- keeps this safe in the Docker `/app` layout, where the
# repo `data/` dir is absent and a fixed index raised IndexError (#70, twin
# #60.P3); there it resolves to `None` and the dedup check simply skips.
_GOLD_STANDARD_PATH = find_in_ancestors(
    Path(__file__), "data/examples/gold_standard.json"
)


async def on_startup(ctx: Dict[str, Any]) -> None:
    """Build the per-worker singletons stashed on ARQ ctx."""
    from app import feature_flags
    from app.logging_config import init_sentry, setup_logging

    # The worker is a separate process from the API — structured logging and
    # the DSN-gated Sentry init (backend arch review 2026-07-18) must run here
    # too, or refund-eligible pipeline failures report nowhere.
    setup_logging()
    init_sentry(get_settings().sentry_dsn)

    # Same migrate-before-deploy boot gate as app/main.py, separate process:
    # a worker that boots against a behind-head schema would otherwise start
    # pulling paid orders off the queue and crash mid-pipeline.
    from app.db.migration_check import assert_migrations_at_head

    await assert_migrations_at_head(get_settings().database_url, logger)

    from app.db.session import AsyncSessionLocal
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.generation.answer_normalizer import AnswerNormalizer
    from app.generation.expiry_classifier import ExpiryClassifier
    from app.scoring.multi_model_scorer import MultiModelScorer
    from app.sourcing.fact_sourcer import FactSourcer
    from app.verification.fact_verifier import FactVerifier
    from app.verification.logical_verifier import LogicalConsistencyVerifier
    from quiz_shared.database.pgvector_client import PgvectorQuestionStore
    from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore
    from quiz_shared.llm import factory as llm_factory

    ctx["session_factory"] = AsyncSessionLocal
    ctx["fact_sourcer"] = FactSourcer()
    # Lever A (issue #72 P1.1): the ARQ worker is the production generation path,
    # so it must honour the GENERATION_MODEL toggle the same way the API path's
    # `_build_advanced_generator` does — otherwise a prod un-park with
    # GENERATION_MODEL set would silently keep generating on gpt-4o. Dormant
    # until the env var is set: with no override the flags return None → the
    # canonical gpt-4o/gpt-4o-mini defaults (output unchanged).
    ctx["generator"] = AdvancedQuestionGenerator(
        generation_model=feature_flags.generation_model() or llm_factory.GEN,
        critique_model=feature_flags.critique_model() or llm_factory.CRITIQUE,
    )
    # 46.A2b — fail-safe to drop when GOOGLE_API_KEY is absent.
    ctx["answer_normalizer"] = AnswerNormalizer()
    # Issue #76 F-3b — post-generation expiry classifier, default OFF. Dormant
    # (`None`) unless EXPIRY_CLASSIFICATION is set, so an un-flagged worker adds
    # no LLM call and leaves expiry unset exactly as before.
    ctx["expiry_classifier"] = (
        ExpiryClassifier() if feature_flags.expiry_classification() else None
    )
    ctx["fact_verifier"] = FactVerifier()
    # 46.B6 — logical-consistency judge for lateral puzzles; fail-safe to
    # `uncertain` when GOOGLE_API_KEY is absent.
    ctx["logical_verifier"] = LogicalConsistencyVerifier()
    ctx["scorer"] = MultiModelScorer()
    # 42.27 — DedupStage dedups against the canonical pgvector corpus (ChromaDB
    # is frozen read-only legacy). SyncPgvectorStore bridges DedupStage's sync
    # `find_duplicates` call to the async store via a background event loop.
    ctx["question_store"] = SyncPgvectorStore(
        PgvectorQuestionStore(session_factory=AsyncSessionLocal)
    )
    # `find_in_ancestors` already returns an existing file or None.
    ctx["gold_standard_path"] = _GOLD_STANDARD_PATH
    logger.info("worker on_startup: collaborators initialised")


class WorkerSettings:
    """ARQ worker configuration.

    max_tries=3 + job_timeout=600 gives the Phase-1 mitigation for R5:
    a stuck job is killed at 10 min and retried up to 3× before failing.
    """

    redis_settings: RedisSettings = RedisSettings.from_dsn(get_settings().redis_url)
    functions = [process_order]
    # #103 F4 — periodic recovery for orders stuck in 'pending'/'in_progress'
    # (dead worker, Redis blip between commit and enqueue). `run_at_startup`
    # is on so a freshly (re)started worker immediately recovers anything a
    # previous, killed worker left stuck, rather than waiting up to 5 min.
    cron_jobs = [
        cron(sweep_stuck_orders, minute=set(range(0, 60, 5)), run_at_startup=True)
    ]
    on_startup = on_startup
    max_jobs: int = 2
    max_tries: int = 3
    job_timeout: int = 600
    keep_result: int = 86400
