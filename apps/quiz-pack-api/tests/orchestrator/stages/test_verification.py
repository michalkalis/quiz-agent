"""Unit tests for VerificationStage (issue #36 task 2.6).

Why these scenarios:

- `test_drops_questions_below_confidence_threshold`: the F8 source-quality
  contract (#32 §3, task 2.15) hinges on verification filtering out
  hallucinated answers. A test that just counts verifier calls without
  asserting the drop would not catch a regression that keeps bad
  questions in the pack.
- `test_publishes_dropped_count_in_stage_info`: SSE clients (#33 task
  1.11) surface per-step info to the iOS UI. The "dropped" count is the
  signal the user/operator sees if the pipeline silently sheds half the
  pack — it must reach the sink via `StageResult.info`.
- `test_merges_verification_into_generation_metadata_extra`: downstream
  scoring + review tooling reads `generation_metadata.extra["verified"]`.
  If the stage drops the verdict on the floor, the audit trail breaks
  and we cannot tell verified from unverified rows later.
- `test_preserves_existing_extra_keys`: `AdvancedQuestionGenerator`
  already populates `extra` (legacy ai_score, ai_reasoning). The
  verification merge must NOT clobber those — R11 in the risk register.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.verification import (
    DEFAULT_MIN_CONFIDENCE,
    VerificationStage,
)
from app.verification.fact_verifier import VerificationResult
from quiz_shared.models.question import GenerationProvenance, Question


class _RecordingSink:
    def __init__(self) -> None:
        self.events: list[tuple[str, str, Any]] = []
        self._next_id = 0

    async def start_step(self, step: str, info: Any = None) -> int:
        eid = self._next_id
        self._next_id += 1
        self.events.append(("start", step, info))
        return eid

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        self.events.append(("finish", step, info))

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        self.events.append(("publish", step, info))


class _FakeFactVerifier:
    """FactVerifier double whose `verify_batch` returns canned verdicts.

    Caller passes a {question_id: VerificationResult} map. Questions
    without a mapped verdict get a default "uncertain" / 0.0 result.
    """

    def __init__(self, verdicts: dict[str, VerificationResult]) -> None:
        self._verdicts = verdicts
        self.calls: list[list[dict[str, Any]]] = []

    async def verify_batch(self, questions: list[dict[str, Any]]) -> list[dict[str, Any]]:
        self.calls.append(questions)
        out: list[dict[str, Any]] = []
        for q in questions:
            qid = q["id"]
            result = self._verdicts.get(
                qid,
                VerificationResult(verdict="uncertain", confidence=0.0),
            )
            out.append(
                {
                    "id": qid,
                    "question": q["question"],
                    "claimed_answer": q["correct_answer"],
                    "verification": result,
                }
            )
        return out


def _stub_question(idx: int, **overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id=f"q_{idx}",
        question=f"stub question {idx}",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _make_ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="famous capitals",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


@pytest.mark.asyncio
async def test_drops_questions_below_confidence_threshold() -> None:
    # 5 questions: 3 verified-high, 2 verified-low — expect 2 drops.
    verdicts = {
        "q_0": VerificationResult(verdict="verified", confidence=0.9),
        "q_1": VerificationResult(verdict="verified", confidence=0.9),
        "q_2": VerificationResult(verdict="likely_correct", confidence=0.7),
        "q_3": VerificationResult(verdict="likely_wrong", confidence=0.2),
        "q_4": VerificationResult(verdict="wrong", confidence=0.1),
    }
    verifier = _FakeFactVerifier(verdicts)
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(i) for i in range(5)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 3
    surviving_ids = {q.id for q in ctx.questions}
    assert surviving_ids == {"q_0", "q_1", "q_2"}
    assert result.info["dropped"] == 2
    assert result.info["verified"] == 3


@pytest.mark.asyncio
async def test_publishes_dropped_count_in_stage_info() -> None:
    verdicts = {
        "q_0": VerificationResult(verdict="verified", confidence=0.9),
        "q_1": VerificationResult(verdict="wrong", confidence=0.05),
    }
    verifier = _FakeFactVerifier(verdicts)
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert "dropped" in result.info
    assert result.info["dropped"] == 1


@pytest.mark.asyncio
async def test_merges_verification_into_generation_metadata_extra() -> None:
    verdicts = {
        "q_0": VerificationResult(
            verdict="verified", confidence=0.88, notes="3/3 sources confirm"
        ),
    }
    verifier = _FakeFactVerifier(verdicts)
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    extra = ctx.questions[0].generation_metadata.extra
    assert extra["verified"] is True
    assert extra["verification_score"] == pytest.approx(0.88)
    assert extra["verification_notes"] == "3/3 sources confirm"


@pytest.mark.asyncio
async def test_preserves_existing_extra_keys() -> None:
    pre = GenerationProvenance(
        model="gpt-4o", extra={"ai_score": 8.5, "ai_reasoning": "clear"}
    )
    q = _stub_question(0, generation_metadata=pre)
    verdicts = {
        "q_0": VerificationResult(verdict="verified", confidence=0.9, notes="ok"),
    }
    verifier = _FakeFactVerifier(verdicts)
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([q])

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    meta = ctx.questions[0].generation_metadata
    assert meta.model == "gpt-4o"  # untouched
    assert meta.extra["ai_score"] == 8.5  # legacy keys preserved
    assert meta.extra["ai_reasoning"] == "clear"
    assert meta.extra["verified"] is True
    assert meta.extra["verification_score"] == pytest.approx(0.9)


@pytest.mark.asyncio
async def test_no_questions_returns_zero_counts() -> None:
    verifier = _FakeFactVerifier({})
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info == {"verified": 0, "dropped": 0}
    assert verifier.calls == []


@pytest.mark.asyncio
async def test_threshold_default_matches_module_constant() -> None:
    """If the default threshold drifts silently, callers cannot reason about
    the drop policy. Pin it here so a behaviour change is loud."""
    assert DEFAULT_MIN_CONFIDENCE == 0.5
