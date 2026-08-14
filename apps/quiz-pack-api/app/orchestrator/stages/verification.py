"""VerificationStage — thin wrapper around FactVerifier (issue #36 task 2.6).

The stage adapts `OrderContext.questions` to the dict-of-strings shape
`FactVerifier.verify_batch` expects, calls the existing verifier, then
merges the per-question verdict back onto each `Question`:

- `generation_metadata.extra["verified"]`         — bool (verdict ∈ verified/likely_correct)
- `generation_metadata.extra["verification_score"]` — float (confidence 0..1)
- `generation_metadata.extra["verification_notes"]` — str  (verifier reasoning)

Questions whose verification confidence falls below `min_confidence` are
dropped from `ctx.questions`. Questions the verifier could NOT check —
`held_for_review` (search/judge unavailable) or no verdict record at all —
are **withheld** (#158, gen-review part-4 verdict: fail closed, an unverified
question never reaches a pack or the corpus; there is no review queue).
Supersedes RC-9's keep-and-tag (#72): the top-up loop regenerates the
shortfall, and a systemic verifier outage breaches TopUp's 80% floor, which
fails the order loud instead of delivering unverified content. Counts are
reported via `StageResult.info` (`dropped`, `withheld`) — PackGenerator
forwards them onto the sink's `publish(...)` call, so SSE clients see how
many were filtered.

Drop policy is intentionally simple: a single confidence threshold. The
Phase 3 score-aware policy lives in `ScoringStage` (task 2.7) and the
follow-up #37 work; we do not stack the two thresholds here.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Optional

import sentry_sdk

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.verification.fact_verifier import MAX_CONCURRENT_VERIFICATIONS, FactVerifier
from app.verification.logical_verifier import LogicalConsistencyVerifier
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

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

        if logical:
            # #150 — same bound as the factual branch (verify_batch) and the
            # scoring/answerability stages; one judge call per question, run
            # concurrently instead of one at a time. `gather` keeps order, so
            # the verdict merged onto each question is unchanged.
            semaphore = asyncio.Semaphore(MAX_CONCURRENT_VERIFICATIONS)

            async def _verify_logical(q: Question):
                async with semaphore:
                    return await self._logical_verifier.verify(
                        q.question, _stringify_answer(q.correct_answer), q.topic
                    )

            logical_results = await asyncio.gather(
                *(_verify_logical(q) for q in logical)
            )
            for q, result in zip(logical, logical_results):
                by_id[q.id] = {"id": q.id, "verification": result}

        kept: list[Question] = []
        dropped = 0
        withheld = 0

        for q in ctx.questions:
            record = by_id.get(q.id)
            if record is None:
                # #158 fail-closed: no verdict came back — a verifier bug, but
                # "unchecked" can never mean "deliverable". Withhold; the
                # top-up loop regenerates the shortfall.
                withheld += 1
                logger.warning(
                    "VerificationStage withheld id=%s: no verdict record "
                    "returned by the verifier (fail-closed, #158)",
                    q.id,
                )
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

            # #158 fail-closed (supersedes RC-9 keep-and-tag): the verifier
            # could not check this question (search/judge unavailable) — it
            # never leaves the pipeline. No review queue exists by design.
            if held:
                withheld += 1
                logger.warning(
                    "VerificationStage withheld id=%s: held_for_review "
                    "(verifier unavailable) — fail-closed, #158; notes=%s",
                    q.id,
                    notes,
                )
                continue
            if confidence < self._min_confidence:
                dropped += 1
                continue
            kept.append(q)

        ctx.questions = kept

        if withheld:
            # Visibility for the outage class behind withholds (Tavily/judge
            # down): warn-level Sentry — one transient search failure self-heals
            # via top-up, a systemic outage breaches the 80% floor and pages
            # through the order-failure path.
            message = (
                f"order {ctx.order_id} verification withheld {withheld} "
                "unverifiable question(s) (fail-closed, #158)"
            )
            logger.warning(message)
            sentry_sdk.capture_message(message, level="warning")

        return StageResult(
            info={"verified": len(kept), "dropped": dropped, "withheld": withheld},
            cost_cents=0,
        )


def _is_logical(q: Question) -> bool:
    """True iff the question routes to the logical-consistency judge (D2).

    #160 (gen-review P4): keyed on the server-audited
    ``pipeline == "logical_puzzle"`` provenance marker — stamped only by the
    server-controlled open branch and confirmed by the answer-blind
    ShapeClassifier in GenerationStage. The old key derived
    ``verification_mode`` from the generator's own ``pattern_used`` label, so
    the model could label a factual claim ``lateral_thinking`` and route it
    past web fact-checking (model-controlled routing).
    """
    return (
        q.generation_metadata is not None
        and q.generation_metadata.pipeline == "logical_puzzle"
    )


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the verifier API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
