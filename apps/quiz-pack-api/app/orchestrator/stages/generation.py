"""GenerationStage — thin wrapper around AdvancedQuestionGenerator (issue #36 task 2.5).

Best-of-N and the LLM judge stay coupled inside `AdvancedQuestionGenerator`
(#32 §1.2 keep-list), so this stage is intentionally thin: it maps
`OrderContext` → the generator's existing `generate_questions` kwargs and
post-processes the returned questions with order-level metadata the
generator itself doesn't know about — `prompt_seed`, `language`, and
the `source_url`/`source_excerpt` carry-over from `Fact` references that
F8 (task 2.15) + the e2e assertion in task 2.11 depend on.
"""

from __future__ import annotations

import hashlib
import logging
import uuid

from app.generation.advanced_generator import AdvancedQuestionGenerator
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.scoring.multi_model_scorer import _ANSWER_TAIL_MARKERS, _ANSWER_WORD_CAP
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except (ValueError, TypeError, AttributeError):
        return False


def _violates_answer_brevity(answer: object) -> str | None:
    """Return a reason string if the answer breaks 42.5/42.7 brevity rules.

    Pure regex/token check (no LLM, per CLAUDE.md rule #5). Mirrors the
    constraints encoded in the v2/v3 prompts: hard cap at 10 words, no
    em/en-dash, no `because` / `namely` / `i.e.` / `which means`. Returns
    `None` when the answer is acceptable so the caller can log the reason
    alongside the dropped question id.
    """
    if answer is None:
        return "empty_answer"
    text = ", ".join(str(a) for a in answer) if isinstance(answer, list) else str(answer)
    if not text.strip():
        return "empty_answer"
    if len(text.split()) > _ANSWER_WORD_CAP:
        return f"over_word_cap_{_ANSWER_WORD_CAP}"
    lowered = text.lower()
    for marker in _ANSWER_TAIL_MARKERS:
        if marker in lowered:
            return f"tail_marker:{marker.strip() or marker!r}"
    return None


def _compute_prompt_seed(
    prompt: str, language: str, category: str | None, theme: str | None
) -> str:
    """Deterministic 16-char hash grouping questions from one user prompt."""
    payload = f"{prompt}|{language}|{category or ''}|{theme or ''}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


class GenerationStage:
    """Calls AdvancedQuestionGenerator.generate_questions; stores Questions on ctx."""

    name = "generating"

    def __init__(self, generator: AdvancedQuestionGenerator) -> None:
        self._generator = generator

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        topics = [t for t in (ctx.category, ctx.theme) if t] or None
        categories = [ctx.category] if ctx.category else None

        questions = await self._generator.generate_questions(
            count=ctx.target_count,
            topics=topics,
            categories=categories,
            source_facts=ctx.facts or None,
        )

        prompt_seed = _compute_prompt_seed(
            ctx.prompt, ctx.language, ctx.category, ctx.theme
        )
        # The Phase 2 wrap has no per-question fact-ID linkage yet — fall back
        # to the first fact with a usable URL. Per-question fact_ids land in
        # Phase 3 when the cache hook (#37 / C3) needs them.
        fallback_fact = next(
            (f for f in ctx.facts if getattr(f, "source_url", None)),
            None,
        )

        for q in questions:
            # AdvancedQuestionGenerator inherits the Phase 1 `q_<hex>` id
            # convention from `app/generation/storage.py`; PersistStage's
            # `_coerce_uuid` (app/db/models/question.py:141) refuses non-UUID
            # ids on purpose. Normalise at the stage boundary so the rest of
            # the orchestrator can rely on uuid-shaped ids.
            if not _is_uuid(q.id):
                q.id = str(uuid.uuid4())

            q.prompt_seed = prompt_seed
            q.language = ctx.language

            provenance = q.generation_metadata or GenerationProvenance()
            if ctx.facts:
                provenance = provenance.model_copy(update={"pipeline": "fact_first"})
            q.generation_metadata = provenance

            if fallback_fact is not None:
                if q.source_url is None:
                    q.source_url = getattr(fallback_fact, "source_url", None)
                if q.source_excerpt is None:
                    q.source_excerpt = getattr(
                        fallback_fact, "excerpt", None
                    ) or getattr(fallback_fact, "text", None)

        # Issue #42 task 42.7 — fail-loud post-generation brevity validator.
        # Drops questions whose `correct_answer` violates the constraints the
        # v2/v3 prompts now require (>10 words, em/en-dash, "because" etc.).
        # Surfaced via StageResult.info["dropped_quality"] so SSE clients and
        # the audit trail see how many got filtered, mirroring DedupStage.
        kept: list[Question] = []
        dropped_quality = 0
        for q in questions:
            reason = _violates_answer_brevity(q.correct_answer)
            if reason is not None:
                dropped_quality += 1
                logger.warning(
                    "GenerationStage dropped question id=%s reason=%s answer=%r",
                    q.id,
                    reason,
                    q.correct_answer,
                )
                continue
            kept.append(q)

        ctx.questions = kept

        # F8 (task 2.15): every persisted question must carry a real source URL.
        # If the per-question fallback above couldn't fill `source_url` (e.g.
        # all sourced facts lacked URLs — OpenTriviaDB without attribution),
        # fail loudly here instead of letting the gap slip into Postgres.
        missing = [q for q in ctx.questions if not q.source_url]
        if missing:
            attributed = sum(
                1 for f in (ctx.facts or []) if getattr(f, "source_url", None)
            )
            raise ValueError(
                f"F8 violated: {len(missing)}/{len(ctx.questions)} questions "
                f"have no source_url after GenerationStage "
                f"({attributed}/{len(ctx.facts or [])} facts had source_url)"
            )

        return StageResult(
            info={"questions": len(ctx.questions), "dropped_quality": dropped_quality},
            cost_cents=0,
        )
