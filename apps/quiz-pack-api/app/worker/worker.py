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

from app.config import get_settings

from .tasks import process_order

logger = logging.getLogger(__name__)

# Locate gold_standard.json relative to the repo root. Used by DedupStage's
# Jaccard check; missing file means the check is a no-op (the stage handles
# `None` by skipping the gold-standard comparison).
_REPO_ROOT = Path(__file__).resolve().parents[4]
_GOLD_STANDARD_PATH = _REPO_ROOT / "data" / "examples" / "gold_standard.json"


async def on_startup(ctx: Dict[str, Any]) -> None:
    """Build the per-worker singletons stashed on ARQ ctx."""
    from app.db.session import AsyncSessionLocal
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.scoring.multi_model_scorer import MultiModelScorer
    from app.sourcing.fact_sourcer import FactSourcer
    from app.verification.fact_verifier import FactVerifier
    from quiz_shared.database.chroma_client import ChromaDBClient

    ctx["session_factory"] = AsyncSessionLocal
    ctx["fact_sourcer"] = FactSourcer()
    ctx["generator"] = AdvancedQuestionGenerator()
    ctx["fact_verifier"] = FactVerifier()
    ctx["scorer"] = MultiModelScorer()
    ctx["question_store"] = ChromaDBClient().store
    ctx["gold_standard_path"] = (
        _GOLD_STANDARD_PATH if _GOLD_STANDARD_PATH.exists() else None
    )
    logger.info("worker on_startup: collaborators initialised")


class WorkerSettings:
    """ARQ worker configuration.

    max_tries=3 + job_timeout=600 gives the Phase-1 mitigation for R5:
    a stuck job is killed at 10 min and retried up to 3× before failing.
    """

    redis_settings: RedisSettings = RedisSettings.from_dsn(get_settings().redis_url)
    functions = [process_order]
    on_startup = on_startup
    max_jobs: int = 2
    max_tries: int = 3
    job_timeout: int = 600
    keep_result: int = 86400
