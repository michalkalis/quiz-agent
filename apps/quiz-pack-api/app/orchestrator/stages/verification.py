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
from app.verification.tier_router import needs_web_factcheck, tier_routing_enabled
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

DEFAULT_MIN_CONFIDENCE = 0.5
# "ok" — FactVerifier's web-grounded Claude fact-check (#166 increment 2);
# "verified"/"likely_correct" — LogicalConsistencyVerifier's older scale.
# FactVerifier maps its problem verdicts (fact_error/logic_flaw/stale) to
# confidence 0.0, so the single min_confidence gate below implements the
# founder-approved drop policy for both vocabularies unchanged.
_VERIFIED_VERDICTS = frozenset({"ok", "verified", "likely_correct"})


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
        #
        # #166 increment 3: evergreen questions additionally skip the web
        # fact-check (deterministic tier_router; founder-approved policy
        # grounded in D21b: 70/70 direct-gen evergreen clean, all 6 errors in
        # news-sourced arms). This is a deliberate no-check tier, not a
        # fail-open path — #158's fail-closed rule still governs every
        # question that *does* route to a verifier.
        route_tiers = tier_routing_enabled()
        factual: list[Question] = []
        logical: list[Question] = []
        evergreen_ids: set[object] = set()
        for q in ctx.questions:
            if self._logical_verifier is not None and _is_logical(q):
                logical.append(q)
            elif route_tiers and not needs_web_factcheck(q):
                evergreen_ids.add(q.id)
            else:
                factual.append(q)

        by_id: dict[object, dict] = {}

        if factual:
            payload = [
                {
                    "id": q.id,
                    "question": _question_with_options(q),
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
        # #166 increment 2: the fact-check runs on the direct Anthropic API,
        # invisible to both order-level cost signals (Tavily credits,
        # OpenRouter delta) — each verdict carries its own cost instead.
        cost_cents = sum(
            float(getattr(record.get("verification"), "cost_cents", 0.0))
            for record in by_id.values()
        )

        for q in ctx.questions:
            if q.id in evergreen_ids:
                # Evergreen tier: kept without a web check, marked so the
                # decision is auditable per question (and distinguishable
                # from a verified "ok" in generation_metadata).
                provenance = q.generation_metadata or GenerationProvenance()
                extra = dict(provenance.extra)
                extra["factcheck_tier"] = "evergreen"
                q.generation_metadata = provenance.model_copy(
                    update={"extra": extra}
                )
                kept.append(q)
                continue

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
            extra["factcheck_tier"] = "web"
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
            # Visibility for the outage class behind withholds (Anthropic
            # fact-check or logical judge down): warn-level Sentry — one transient search failure self-heals
            # via top-up, a systemic outage breaches the 80% floor and pages
            # through the order-failure path.
            message = (
                f"order {ctx.order_id} verification withheld {withheld} "
                "unverifiable question(s) (fail-closed, #158)"
            )
            logger.warning(message)
            sentry_sdk.capture_message(message, level="warning")

        return StageResult(
            info={
                "verified": len(kept),
                "dropped": dropped,
                "withheld": withheld,
                "evergreen_skipped": len(evergreen_ids),
            },
            cost_cents=int(round(cost_cents)),
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


def _question_with_options(q: Question) -> str:
    """The stem the verifier should judge — with an MCQ's options attached.

    An MCQ's claimed answer is only ever "the right one of these", never an
    exact measurement: "3,800 years" is the correct bucket for a pyramid that
    held the record for ~3,871 years, and "Tens of thousands of years" is a
    range. Sending the bare stem asked the web verifier to confirm an exact
    figure and let it drop correct questions as `fact_error` — a risk the
    inline-option repair sharpens, because the options it lifts OUT of the
    stem are exactly the context the verifier used to read (PR #76 review,
    finding 5). Free-text questions are unchanged.
    """
    if not q.possible_answers:
        return q.question
    options = " / ".join(str(v) for v in q.possible_answers.values())
    return f"{q.question} (multiple choice — the options are: {options})"


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the verifier API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
