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
from app.generation.answer_normalizer import AnswerNormalizer
from app.generation.pattern_routing import (
    PATTERNS_TO_MCQ,
    choose_question_type,
    verification_mode,
)
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


# Issue #46 task 46.A2 — deterministic split markers for normalize-then-drop.
# Only UNAMBIGUOUS markers: an em/en-dash or one of these connectives always
# introduces an explanatory tail after a canonical head. A bare comma is
# deliberately excluded — it is structural in legitimate short answers
# ("Tokyo, Japan", "December 7, 1941", "salt, pepper, flour"), so comma-tailed
# verbose answers are NOT split here; they route to the LLM normalization
# fallback (46.A2b) where "canonical head vs. one indivisible answer?" is a
# judgment call (CLAUDE.md rule #5). Word markers carry surrounding spaces so
# they never match inside a longer token.
_DETERMINISTIC_SPLIT_MARKERS = (
    "—",  # em-dash
    "–",  # en-dash
    " because ",
    " while ",
    " namely ",
    " due to ",
    " i.e.",
)


def _split_answer_head(answer: str) -> tuple[str, str] | None:
    """Deterministically split a verbose answer into (head, explanation_tail).

    Returns the canonical short head and the explanatory tail when a clean
    head sits before the earliest unambiguous tail marker; returns ``None``
    when no marker is present or the head is itself empty/over the word cap
    (i.e. there is no recoverable short answer — the caller must drop or defer
    to the LLM fallback). Never splits on a bare comma.
    """
    lowered = answer.lower()
    earliest: tuple[int, int] | None = None  # (index, marker_len)
    for marker in _DETERMINISTIC_SPLIT_MARKERS:
        idx = lowered.find(marker)
        if idx > 0 and (earliest is None or idx < earliest[0]):
            earliest = (idx, len(marker))
    if earliest is None:
        return None
    idx, _mlen = earliest
    head = answer[:idx].strip(" ,;:")
    # Strip the dash glyph from a tail's lead but keep connective words
    # ("because the wall…") so the explanation reads naturally.
    tail = answer[idx:].lstrip(" —–").strip()
    if not head or _violates_answer_brevity(head) is not None:
        return None
    return head, tail


def _merge_explanation(existing: str | None, tail: str) -> str:
    """Append a recovered answer tail to any existing explanation."""
    existing = (existing or "").strip()
    if not existing:
        return tail
    return f"{existing} {tail}".strip()


def _compute_prompt_seed(
    prompt: str, language: str, category: str | None, theme: str | None
) -> str:
    """Deterministic 16-char hash grouping questions from one user prompt."""
    payload = f"{prompt}|{language}|{category or ''}|{theme or ''}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


class GenerationStage:
    """Calls AdvancedQuestionGenerator.generate_questions; stores Questions on ctx."""

    name = "generating"

    def __init__(
        self,
        generator: AdvancedQuestionGenerator,
        answer_normalizer: AnswerNormalizer | None = None,
    ) -> None:
        self._generator = generator
        # Issue #46 task 46.A2b — optional LLM normalizer for the ambiguous
        # comma-tailed remainder the deterministic splitter can't recover.
        # `None` keeps the 46.A2 fail-safe behaviour (those answers drop).
        self._answer_normalizer = answer_normalizer

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        topics = [t for t in (ctx.category, ctx.theme) if t] or None
        categories = [ctx.category] if ctx.category else None

        questions = await self._generator.generate_questions(
            count=ctx.target_count,
            topics=topics,
            categories=categories,
            source_facts=ctx.facts or None,
            # Issue #42 task 42.9b — the generator passes these into the
            # `{mcq_patterns_section}` of the prompt so the LLM emits
            # `possible_answers` + key-letter `correct_answer` for any
            # MCQ-routed pattern. The downstream 42.9a step (below) then
            # tags the question type from the LLM's chosen pattern.
            mcq_patterns=set(PATTERNS_TO_MCQ),
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

        # Issue #42 task 42.7 + #46 task 46.A2 — post-generation brevity
        # validator, now **normalize-then-drop** instead of drop-only. A
        # `correct_answer` with a clean short head before an unambiguous tail
        # marker (em/en-dash, "because", "while", …) is split: head stays in
        # `correct_answer`, tail moves to `explanation` so nothing is lost. A
        # question is dropped only when no recoverable short head exists (the
        # comma-tailed ambiguous remainder defers to the LLM fallback, 46.A2b).
        # `dropped_quality` / `normalized_quality` are surfaced via
        # StageResult.info so SSE clients + the audit trail see the activity,
        # mirroring DedupStage.
        kept: list[Question] = []
        dropped_quality = 0
        normalized_quality = 0
        for q in questions:
            reason = _violates_answer_brevity(q.correct_answer)
            if reason is None:
                kept.append(q)
                continue
            split = (
                _split_answer_head(q.correct_answer)
                if isinstance(q.correct_answer, str)
                else None
            )
            if split is not None:
                head, tail = split
                q.explanation = _merge_explanation(q.explanation, tail)
                q.correct_answer = head
                normalized_quality += 1
                logger.info(
                    "GenerationStage normalized question id=%s head=%r reason=%s",
                    q.id,
                    head,
                    reason,
                )
                kept.append(q)
                continue
            # 46.A2b — deterministic split failed (comma-tailed / no marker).
            # Defer to the optional LLM normalizer for the judgment call
            # "canonical head + appositive vs. one indivisible answer?". It
            # fail-safes to None (→ drop) when unavailable or low-confidence,
            # so nothing is normalized to a guess.
            if self._answer_normalizer is not None and isinstance(
                q.correct_answer, str
            ):
                normalized = await self._answer_normalizer.normalize(
                    q.question, q.correct_answer
                )
                if normalized is not None:
                    if normalized.explanation:
                        q.explanation = _merge_explanation(
                            q.explanation, normalized.explanation
                        )
                    q.correct_answer = normalized.head
                    normalized_quality += 1
                    logger.info(
                        "GenerationStage LLM-normalized question id=%s head=%r "
                        "reason=%s",
                        q.id,
                        normalized.head,
                        reason,
                    )
                    kept.append(q)
                    continue
            dropped_quality += 1
            logger.warning(
                "GenerationStage dropped question id=%s reason=%s answer=%r",
                q.id,
                reason,
                q.correct_answer,
            )

        # Issue #42 task 42.9a — post-generation type tagging for MCQ.
        # The LLM picks the reasoning pattern per question (stored on the
        # provenance as `reasoning_pattern`); if that pattern is in the MCQ
        # set, the question must surface as `text_multichoice` so the iOS
        # `MCQOptionPicker` activates and the evaluator's fast-path routes
        # by `possible_answers`. Drop fail-loud when a pattern requires MCQ
        # but the generator didn't emit options — a half-built MCQ is worse
        # than no MCQ (evaluator would silently degrade to free-text and the
        # iOS UI would have nothing to show).
        tagged: list[Question] = []
        dropped_mcq_missing_options = 0
        for q in kept:
            pattern = (
                q.generation_metadata.reasoning_pattern
                if q.generation_metadata is not None
                else None
            )
            desired_type = choose_question_type(pattern)
            if desired_type == "text_multichoice":
                if q.possible_answers:
                    q.type = "text_multichoice"
                    tagged.append(q)
                else:
                    dropped_mcq_missing_options += 1
                    logger.warning(
                        "GenerationStage dropped question id=%s reason=mcq_missing_options "
                        "pattern=%s",
                        q.id,
                        pattern,
                    )
                    continue
            else:
                tagged.append(q)

        # Issue #46 task 46.B4 — open/logical branch tagging (post-route, D1).
        # A question whose `verification_mode` is "logical" (a pure lateral
        # puzzle, by reasoning pattern or open framing) has no external source
        # to attribute — mark its provenance `pipeline = "logical_puzzle"` so
        # (a) VerificationStage (46.B6) routes it to the consistency judge and
        # (b) the F8 relaxation below skips it. Fail-safe: everything else
        # stays factual and keeps the hard source_url requirement (D4/R3).
        # Prompt-side generation through `question_generation_open.md` (46.B3)
        # is deferred to 46.B4b; this tags the existing factual output so the
        # contract + F8 relaxation are exercised end to end first.
        for q in tagged:
            pattern = (
                q.generation_metadata.reasoning_pattern
                if q.generation_metadata is not None
                else None
            )
            if verification_mode(pattern, q.question) == "logical":
                provenance = q.generation_metadata or GenerationProvenance()
                q.generation_metadata = provenance.model_copy(
                    update={"pipeline": "logical_puzzle"}
                )

        ctx.questions = tagged

        # F8 (task 2.15): every persisted question must carry a real source URL.
        # If the per-question fallback above couldn't fill `source_url` (e.g.
        # all sourced facts lacked URLs — OpenTriviaDB without attribution),
        # fail loudly here instead of letting the gap slip into Postgres.
        # Issue #46 D4/D5: logical puzzles (`pipeline == "logical_puzzle"`) are
        # exempt — they are invented, have no web source, and ship with
        # `source_url = null` plus a provenance marker. The relaxation is keyed
        # strictly on that marker (set only by the open branch above) so a
        # mislabelled factual question can never slip through unsourced (R3).
        missing = [
            q
            for q in ctx.questions
            if not q.source_url
            and not (
                q.generation_metadata is not None
                and q.generation_metadata.pipeline == "logical_puzzle"
            )
        ]
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
            info={
                "questions": len(ctx.questions),
                "dropped_quality": dropped_quality,
                "normalized_quality": normalized_quality,
                "dropped_mcq_missing_options": dropped_mcq_missing_options,
            },
            cost_cents=0,
        )
