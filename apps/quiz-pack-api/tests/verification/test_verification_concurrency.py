"""Verification runs its per-question calls concurrently (#150).

Verification was the last per-question stage still awaiting one question at a
time, while both its neighbours (`AnswerabilityStage`, `MultiModelScorer.
score_batch`) already gathered under a semaphore. That made verification
wall-clock scale linearly with pack size inside the single 1200s per-stage
belt — a pack_30 with slow Tavily/arbiter round trips can burn the belt and
discard a paid order after all sourcing + generation spend.

What these tests protect:

- `test_verify_batch_runs_concurrently`: N deliberately slow verifications
  must finish in roughly ONE round trip, not N. Timing is the only way to
  express "concurrent" here — a call-count assertion passes under the
  sequential code too.
- `test_verify_batch_preserves_order_and_content`: concurrency must not
  reshuffle or reshape the batch. `VerificationStage` indexes verdicts by id,
  but a caller reading positionally (or a reviewer diffing a batch) must see
  the same list the sequential version produced.
- `test_logical_branch_runs_concurrently`: the logical-verifier branch of
  `VerificationStage` is a second per-question loop and got the same bound;
  without a test it would silently drift back to sequential.
- `test_concurrency_is_bounded`: the semaphore must actually cap in-flight
  calls — an unbounded `gather` over a pack_30 would hammer the search/LLM
  providers.
"""

from __future__ import annotations

import asyncio
import time
import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.verification import VerificationStage
from app.verification import fact_verifier as fact_verifier_module
from app.verification.fact_verifier import FactVerifier, VerificationResult
from quiz_shared.models.question import GenerationProvenance, Question

_DELAY = 0.1
_BATCH = 12


class _NullSink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        return None

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        return None


def _payload(n: int) -> list[dict[str, Any]]:
    return [
        {
            "id": f"q_{i}",
            "question": f"question {i}",
            "correct_answer": f"answer {i}",
            "topic": "General",
        }
        for i in range(n)
    ]


def _slow_verifier(delay: float = _DELAY) -> FactVerifier:
    """Real FactVerifier with only the per-question `verify` leg stubbed slow."""
    verifier = FactVerifier.__new__(FactVerifier)

    async def _verify(question: str, claimed_answer: str, topic: str = "", **_: Any):
        await asyncio.sleep(delay)
        return VerificationResult(verdict="verified", confidence=0.9, notes=question)

    verifier.verify = _verify  # type: ignore[method-assign]
    return verifier


@pytest.mark.asyncio
async def test_verify_batch_runs_concurrently() -> None:
    started = time.perf_counter()
    results = await _slow_verifier().verify_batch(_payload(_BATCH))
    elapsed = time.perf_counter() - started

    assert len(results) == _BATCH
    # Sequential would be _BATCH * _DELAY (1.2s); one round trip is _DELAY.
    # The 4x headroom keeps this off CI's flake floor while still failing
    # loud on a return to the sequential loop.
    assert elapsed < _DELAY * 4, f"verify_batch took {elapsed:.2f}s — still sequential?"


@pytest.mark.asyncio
async def test_verify_batch_preserves_order_and_content() -> None:
    payload = _payload(_BATCH)
    results = await _slow_verifier(delay=0.0).verify_batch(payload)

    assert [r["id"] for r in results] == [q["id"] for q in payload]
    assert [r["question"] for r in results] == [q["question"] for q in payload]
    assert [r["claimed_answer"] for r in results] == [
        q["correct_answer"] for q in payload
    ]
    # The verdict that came back belongs to THAT question, not a neighbour.
    assert [r["verification"].notes for r in results] == [
        q["question"] for q in payload
    ]


@pytest.mark.asyncio
async def test_concurrency_is_bounded(monkeypatch) -> None:
    monkeypatch.setattr(fact_verifier_module, "MAX_CONCURRENT_VERIFICATIONS", 3)
    verifier = FactVerifier.__new__(FactVerifier)
    in_flight = 0
    peak = 0

    async def _verify(question: str, claimed_answer: str, topic: str = "", **_: Any):
        nonlocal in_flight, peak
        in_flight += 1
        peak = max(peak, in_flight)
        await asyncio.sleep(_DELAY)
        in_flight -= 1
        return VerificationResult(verdict="verified", confidence=0.9)

    verifier.verify = _verify  # type: ignore[method-assign]

    await verifier.verify_batch(_payload(_BATCH))

    assert peak == 3, f"semaphore did not bound in-flight verifications (peak {peak})"


@pytest.mark.asyncio
async def test_logical_branch_runs_concurrently() -> None:
    class _SlowLogicalVerifier:
        async def verify(self, question: str, answer: str, topic: str = ""):
            await asyncio.sleep(_DELAY)
            return VerificationResult(verdict="verified", confidence=0.8)

    class _UnusedFactVerifier:
        async def verify_batch(self, questions: list[dict[str, Any]]):
            return []

    puzzles = [
        Question(
            id=f"q_{i}",
            question=f"A man pushes his car to a hotel {i}. What happened?",
            correct_answer="he is playing Monopoly",
            topic="General",
            category="general",
            difficulty="medium",
            generation_metadata=GenerationProvenance(
                reasoning_pattern="lateral_thinking",
                pipeline="logical_puzzle",  # #160: dispatch keys on the marker
            ),
        )
        for i in range(_BATCH)
    ]
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="lateral puzzles",
        language="en",
        target_count=_BATCH,
    )
    ctx.questions = list(puzzles)

    stage = VerificationStage(
        _UnusedFactVerifier(),  # type: ignore[arg-type]
        _SlowLogicalVerifier(),  # type: ignore[arg-type]
    )
    started = time.perf_counter()
    result = await stage.run(ctx, _NullSink())  # type: ignore[arg-type]
    elapsed = time.perf_counter() - started

    assert elapsed < _DELAY * 4, f"logical branch took {elapsed:.2f}s — sequential?"
    # Same verdicts as before: every puzzle verified, none dropped, order kept.
    assert result.info == {"verified": _BATCH, "dropped": 0, "withheld": 0, "evergreen_skipped": 0}
    assert [q.id for q in ctx.questions] == [q.id for q in puzzles]
