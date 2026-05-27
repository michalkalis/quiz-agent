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

from app.generation.advanced_generator import AdvancedQuestionGenerator
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from quiz_shared.models.question import GenerationProvenance


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

        ctx.questions = list(questions)

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
            info={"questions": len(ctx.questions)},
            cost_cents=0,
        )
