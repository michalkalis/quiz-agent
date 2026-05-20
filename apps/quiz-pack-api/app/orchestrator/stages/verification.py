"""VerificationStage — thin wrapper around FactVerifier (issue #36 task 2.6).

The stage adapts `OrderContext.questions` to the dict-of-strings shape
`FactVerifier.verify_batch` expects, calls the existing verifier, then
merges the per-question verdict back onto each `Question`:

- `generation_metadata.extra["verified"]`         — bool (verdict ∈ verified/likely_correct)
- `generation_metadata.extra["verification_score"]` — float (confidence 0..1)
- `generation_metadata.extra["verification_notes"]` — str  (verifier reasoning)

Questions whose verification confidence falls below `min_confidence` are
dropped from `ctx.questions`. The drop count is reported via the
`StageResult.info["dropped"]` field — PackGenerator forwards it onto the
sink's `publish(...)` call, so SSE clients see how many were filtered.

Drop policy is intentionally simple: a single confidence threshold. The
Phase 3 score-aware policy lives in `ScoringStage` (task 2.7) and the
follow-up #37 work; we do not stack the two thresholds here.
"""

from __future__ import annotations

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.verification.fact_verifier import FactVerifier
from quiz_shared.models.question import GenerationProvenance, Question

DEFAULT_MIN_CONFIDENCE = 0.5
_VERIFIED_VERDICTS = frozenset({"verified", "likely_correct"})


class VerificationStage:
    """Calls FactVerifier.verify_batch; merges verdicts; drops low-confidence questions."""

    name = "verifying"

    def __init__(
        self,
        fact_verifier: FactVerifier,
        min_confidence: float = DEFAULT_MIN_CONFIDENCE,
    ) -> None:
        self._fact_verifier = fact_verifier
        self._min_confidence = min_confidence

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"verified": 0, "dropped": 0}, cost_cents=0)

        payload = [
            {
                "id": q.id,
                "question": q.question,
                "correct_answer": _stringify_answer(q.correct_answer),
                "topic": q.topic,
            }
            for q in ctx.questions
        ]
        results = await self._fact_verifier.verify_batch(payload)

        by_id = {r.get("id"): r for r in results}
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
            verified_flag = verdict in _VERIFIED_VERDICTS

            provenance = q.generation_metadata or GenerationProvenance()
            extra = dict(provenance.extra)
            extra["verified"] = verified_flag
            extra["verification_score"] = confidence
            extra["verification_notes"] = notes
            q.generation_metadata = provenance.model_copy(update={"extra": extra})

            if confidence < self._min_confidence:
                dropped += 1
                continue
            kept.append(q)

        ctx.questions = kept

        return StageResult(
            info={"verified": len(kept), "dropped": dropped},
            cost_cents=0,
        )


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the verifier API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
