"""VerificationStage — thin wrapper around FactVerifier (issue #36 task 2.6).

The stage adapts `OrderContext.questions` to the dict-of-strings shape
`FactVerifier.verify_batch` expects, calls the existing verifier, then
merges the per-question verdict back onto each `Question`:

- `generation_metadata.extra["verified"]`         — bool (verdict ∈ verified/likely_correct)
- `generation_metadata.extra["verification_score"]` — float (confidence 0..1)
- `generation_metadata.extra["verification_notes"]` — str  (verifier reasoning)

Questions whose verification confidence falls below `min_confidence` are
dropped from `ctx.questions`. Questions the verifier explicitly held for
review (`held_for_review`, e.g. search/judge unavailable) are exempt — kept
and tagged rather than dropped at confidence 0 (RC-9, #72). The drop count is
reported via the
`StageResult.info["dropped"]` field — PackGenerator forwards it onto the
sink's `publish(...)` call, so SSE clients see how many were filtered.

Drop policy is intentionally simple: a single confidence threshold. The
Phase 3 score-aware policy lives in `ScoringStage` (task 2.7) and the
follow-up #37 work; we do not stack the two thresholds here.
"""

from __future__ import annotations

from typing import Optional

from app.generation.pattern_routing import verification_mode
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.verification.fact_verifier import FactVerifier
from app.verification.logical_verifier import LogicalConsistencyVerifier
from quiz_shared.models.question import GenerationProvenance, Question

DEFAULT_MIN_CONFIDENCE = 0.5
_VERIFIED_VERDICTS = frozenset({"verified", "likely_correct"})


class VerificationStage:
    """Dispatches per question to the right verifier; merges verdicts; drops low-confidence.

    Issue #46 D2: a question's ``verification_mode`` (derived from its
    reasoning pattern + text) decides which verifier judges it. Pure
    lateral puzzles (``"logical"``) have no web source, so they go to
    ``LogicalConsistencyVerifier``; everything else (``"factual"``) goes
    to ``FactVerifier`` as before. When no logical verifier is supplied,
    logical questions fall back to ``FactVerifier`` (R2: default to web
    verification on any uncertainty rather than skipping it).
    """

    name = "verifying"

    def __init__(
        self,
        fact_verifier: FactVerifier,
        logical_verifier: Optional[LogicalConsistencyVerifier] = None,
        min_confidence: float = DEFAULT_MIN_CONFIDENCE,
    ) -> None:
        self._fact_verifier = fact_verifier
        self._logical_verifier = logical_verifier
        self._min_confidence = min_confidence

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"verified": 0, "dropped": 0}, cost_cents=0)

        # Dispatch by verification mode (D2). Logical questions only divert
        # to the consistency judge when one is wired; otherwise they stay
        # on FactVerifier (R2 fail-safe — never skip verification).
        factual: list[Question] = []
        logical: list[Question] = []
        for q in ctx.questions:
            if self._logical_verifier is not None and _is_logical(q):
                logical.append(q)
            else:
                factual.append(q)

        by_id: dict[object, dict] = {}

        if factual:
            payload = [
                {
                    "id": q.id,
                    "question": q.question,
                    "correct_answer": _stringify_answer(q.correct_answer),
                    "topic": q.topic,
                }
                for q in factual
            ]
            for record in await self._fact_verifier.verify_batch(payload):
                by_id[record.get("id")] = record

        for q in logical:
            result = await self._logical_verifier.verify(
                q.question, _stringify_answer(q.correct_answer), q.topic
            )
            by_id[q.id] = {"id": q.id, "verification": result}

        kept: list[Question] = []
        dropped = 0

        for q in ctx.questions:
            record = by_id.get(q.id)
            if record is None:
                # No verdict came back — keep the question rather than silently
                # dropping it. A missing verdict is a verifier bug, not a
                # signal that the question is wrong.
                kept.append(q)
                continue

            verification = record.get("verification")
            confidence = float(getattr(verification, "confidence", 0.0))
            verdict = getattr(verification, "verdict", "uncertain")
            notes = getattr(verification, "notes", "")
            held = bool(getattr(verification, "held_for_review", False))
            verified_flag = verdict in _VERIFIED_VERDICTS

            provenance = q.generation_metadata or GenerationProvenance()
            extra = dict(provenance.extra)
            extra["verified"] = verified_flag
            extra["verification_score"] = confidence
            extra["verification_notes"] = notes
            if held:
                extra["held_for_review"] = True
            q.generation_metadata = provenance.model_copy(update={"extra": extra})

            # RC-9 (#72): a question the verifier could not check (search/judge
            # unavailable) is held for review, never dropped at low confidence.
            if held:
                kept.append(q)
                continue
            if confidence < self._min_confidence:
                dropped += 1
                continue
            kept.append(q)

        ctx.questions = kept

        return StageResult(
            info={"verified": len(kept), "dropped": dropped},
            cost_cents=0,
        )


def _is_logical(q: Question) -> bool:
    """True iff the question routes to the logical-consistency judge (D2).

    Keyed on ``verification_mode`` derived from the generator's reasoning
    pattern + question text — the same signal the open-branch generator
    used to tag ``pipeline = "logical_puzzle"``.
    """
    pattern = q.generation_metadata.reasoning_pattern if q.generation_metadata else None
    return verification_mode(pattern, q.question) == "logical"


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the verifier API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
