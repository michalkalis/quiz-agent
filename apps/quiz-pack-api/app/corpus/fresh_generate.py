"""One language's generation for the weekly fresh-entertainment run (#202 202.3).

Runs the standard offline stage walk (``offline_stages.build_stages``) on an
in-memory order — no ``PersistStage`` (it would stamp a ``pack_id``), dedup
against the live corpus via pgvector, ``floor_fraction=0`` (a short week is
fine), judges off, generator and blind answerer pinned — and measures its
spend:

- tokens: everything the ``UsageRecorder`` saw (LangChain calls plus the
  fact-check's ``record_direct``);
- fact-check web-search fees: ``ctx.cost_cents`` is the fact-check's tokens
  PLUS its searches (``fact_verifier._record_usage``), so its token part (the
  recorder's ``verifying`` entry for the fact-check model) is subtracted —
  each cent is counted once.

Not counted (fail loud, not silently): embeddings (OpenAI, fractions of a
cent per run) — see ``llm_usage.COVERAGE_NOTE``.
"""

from __future__ import annotations

import argparse
import logging
from dataclasses import dataclass, field
from typing import Any

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

from app import llm_usage
from app.corpus.fresh_roles import ANSWERABILITY_PIN, OPUS

logger = logging.getLogger(__name__)

FACTCHECK_STAGE = "verifying"


@dataclass
class GenerationResult:
    questions: list[Question] = field(default_factory=list)
    tokens_cents: float = 0.0
    factcheck_search_cents: float = 0.0
    unpriced_models: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def cost_cents(self) -> float:
        return self.tokens_cents + self.factcheck_search_cents


def pipeline_spend_cents(
    usage_summary: dict, stage_cost_cents: float, factcheck_model: str
) -> tuple[float, float]:
    """``(tokens, fact-check search fees)`` in cents, without double counting."""
    tokens = float(usage_summary.get("total_cost_cents_known") or 0.0)
    fc_entry = (
        usage_summary.get("stages", {}).get(FACTCHECK_STAGE, {}).get(factcheck_model)
    )
    fc_tokens = float((fc_entry or {}).get("cost_cents") or 0.0)
    return tokens, max(float(stage_cost_cents) - fc_tokens, 0.0)


class _LogSink:
    """Progress sink for a headless run: one log line per stage."""

    async def start_step(self, step: str, info: dict[str, Any] | None = None) -> int:
        logger.info("start %s %s", step, info or "")
        return 0

    async def finish_step(
        self, step: str, event_id: int, info: dict[str, Any] | None = None
    ) -> None:
        logger.info("finish %s %s", step, info or "")

    async def publish(self, event_id, step, progress, info=None) -> None:
        return None


def build_fresh_stages(lang: str, dedup_store) -> list:
    """The pinned walk: no persist, live dedup, no top-up floor, judges off."""
    from app.orchestrator.offline_stages import build_stages

    return build_stages(
        persist=False,
        dedup_store=dedup_store,
        judges=False,
        floor_fraction=0,
        generation_model=OPUS,
        answerability_model=ANSWERABILITY_PIN[lang],
    )


def build_fresh_order(lang: str, brief: str, count: int):
    from app.orchestrator.offline_stages import build_order

    return build_order(
        argparse.Namespace(
            prompt=brief,
            mcq_bias=False,
            category="entertainment",
            theme=None,
            target_count=count,
            language=lang,
            direct=True,
            grounded=False,
        )
    )


async def generate_language(lang: str, brief: str, count: int) -> GenerationResult:
    """Run the pipeline once; never raises — a failure lands in ``error``."""
    from quiz_shared.database.pgvector_client import PgvectorQuestionStore

    from app.db.session import AsyncSessionLocal
    from app.orchestrator import PackGenerator

    result = GenerationResult()
    recorder = llm_usage.UsageRecorder()
    # Registered BEFORE the stages are built: clients pick it up at construction.
    llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(recorder))
    generator = None
    try:
        stages = build_fresh_stages(
            lang, PgvectorQuestionStore(session_factory=AsyncSessionLocal)
        )
        generator = PackGenerator(stages=stages, sink_factory=lambda _id: _LogSink())
        await generator.run(build_fresh_order(lang, brief, count))
    except Exception as exc:  # the spend so far still counts against the cap
        logger.exception("fresh generation %s failed", lang)
        result.error = f"{type(exc).__name__}: {exc}"
    finally:
        llm_factory.set_usage_handler(None)
    ctx = generator.last_ctx if generator is not None else None
    if ctx is not None:
        result.questions = list(ctx.questions)
    summary = recorder.summary()
    result.tokens_cents, result.factcheck_search_cents = pipeline_spend_cents(
        summary, ctx.cost_cents if ctx else 0, llm_factory.FACTCHECK
    )
    result.unpriced_models = summary.get("unpriced_models", [])
    return result


def post_filter(
    questions: list[Question], lang: str
) -> tuple[list[Question], dict[str, int]]:
    """Drop rows with no ``source_url`` or in another language (plan Krok 4)."""
    kept: list[Question] = []
    dropped: dict[str, int] = {}
    for q in questions:
        reason = None
        if not (q.source_url or "").strip():
            reason = "no_source_url"
        elif q.language != lang:
            reason = "wrong_language"
        if reason:
            dropped[reason] = dropped.get(reason, 0) + 1
        else:
            kept.append(q)
    return kept, dropped
