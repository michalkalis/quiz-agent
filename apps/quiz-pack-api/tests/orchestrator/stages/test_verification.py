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
from app.verification.fact_verifier import FactVerifier, VerificationResult
from app.verification.logical_verifier import LogicalConsistencyVerifier
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

    async def verify_batch(
        self, questions: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
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
async def test_factcheck_verdicts_keep_ok_and_drop_problems() -> None:
    """#166 increment 2 vocabulary: "ok" counts as verified/kept; the problem
    verdicts (fact_error/logic_flaw/stale) arrive at confidence 0.0 and must
    be dropped — the founder-approved drop policy rides the existing gate."""
    verdicts = {
        "q_0": VerificationResult(verdict="ok", confidence=0.9),
        "q_1": VerificationResult(verdict="fact_error", confidence=0.0),
        "q_2": VerificationResult(verdict="stale", confidence=0.0),
        "q_3": VerificationResult(verdict="logic_flaw", confidence=0.0),
    }
    stage = VerificationStage(_FakeFactVerifier(verdicts))  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(i) for i in range(4)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert {q.id for q in ctx.questions} == {"q_0"}
    assert ctx.questions[0].generation_metadata.extra["verified"] is True
    assert result.info == {"verified": 1, "dropped": 3, "withheld": 0, "evergreen_skipped": 0}


@pytest.mark.asyncio
async def test_held_for_review_question_is_withheld() -> None:
    """#158 fail-closed (gen-review part-4 verdict, supersedes RC-9 #72):
    a question the verifier could not check (search/judge unavailable) is
    `held_for_review` — and a held question never reaches a pack or the
    corpus. There is no review queue by design; the top-up loop regenerates
    the shortfall, and a systemic verifier outage breaches TopUp's 80% floor,
    failing the order loud instead of delivering unverified content."""
    verdicts = {
        "q_0": VerificationResult(
            verdict="unverified", confidence=0.3, held_for_review=True
        ),
        # Low confidence, NOT held — a normal drop (verifier worked).
        "q_1": VerificationResult(verdict="likely_wrong", confidence=0.3),
    }
    verifier = _FakeFactVerifier(verdicts)
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert ctx.questions == []  # held withheld, low-confidence dropped
    assert result.info["dropped"] == 1
    assert result.info["withheld"] == 1
    assert result.info["verified"] == 0


@pytest.mark.asyncio
async def test_missing_verdict_record_is_withheld() -> None:
    """#158 fail-closed: no verdict record for a question is a verifier bug,
    but "unchecked" can never mean "deliverable" — the old behavior kept it
    silently, which shipped unverified content on a paid pack."""

    class _AmnesiacVerifier(_FakeFactVerifier):
        async def verify_batch(self, questions):  # type: ignore[override]
            records = await super().verify_batch(questions)
            return [r for r in records if r["id"] != "q_1"]

    verifier = _AmnesiacVerifier(
        {"q_0": VerificationResult(verdict="verified", confidence=0.9)}
    )
    stage = VerificationStage(verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert {q.id for q in ctx.questions} == {"q_0"}
    assert result.info["withheld"] == 1
    assert result.info["dropped"] == 0


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
    assert verifier.calls == []  # early return has no withheld key — nothing ran


class _FakeLogicalVerifier:
    """LogicalConsistencyVerifier double recording which questions it judged."""

    def __init__(self, verdicts: dict[str, VerificationResult]) -> None:
        self._verdicts = verdicts
        self.calls: list[str] = []

    async def verify(
        self, question: str, claimed_answer: str, topic: str = ""
    ) -> VerificationResult:
        self.calls.append(question)
        return self._verdicts.get(
            question, VerificationResult(verdict="uncertain", confidence=0.0)
        )


@pytest.mark.asyncio
async def test_dispatches_logical_questions_to_logical_verifier() -> None:
    """D2/46.B6: a question whose verification_mode is "logical" (lateral
    puzzle pattern) must be judged by LogicalConsistencyVerifier, never sent
    to FactVerifier — a web search on a sourceless puzzle is exactly the
    spurious-match failure this branch exists to avoid."""
    # #160: dispatch keys on the server-audited pipeline marker, not the
    # generator's own reasoning_pattern label.
    puzzle = _stub_question(
        0,
        question="A man pushes his car to a hotel. What happened?",
        generation_metadata=GenerationProvenance(
            reasoning_pattern="lateral_thinking", pipeline="logical_puzzle"
        ),
    )
    factual = _stub_question(
        1,
        question="What is the capital of France?",
        generation_metadata=GenerationProvenance(reasoning_pattern="true_false"),
    )
    fact_verifier = _FakeFactVerifier(
        {"q_1": VerificationResult(verdict="verified", confidence=0.9)}
    )
    logical_verifier = _FakeLogicalVerifier(
        {puzzle.question: VerificationResult(verdict="verified", confidence=0.8)}
    )
    stage = VerificationStage(fact_verifier, logical_verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([puzzle, factual])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    # The puzzle went only to the logical judge; the factual one only to FactVerifier.
    assert logical_verifier.calls == [puzzle.question]
    factual_ids = {q["id"] for batch in fact_verifier.calls for q in batch}
    assert factual_ids == {"q_1"}
    assert {q.id for q in ctx.questions} == {"q_0", "q_1"}
    assert result.info["verified"] == 2


@pytest.mark.asyncio
async def test_logical_questions_fall_back_to_fact_verifier_when_unwired() -> None:
    """R2: with no logical verifier supplied, a logical-mode question must
    still be web-verified rather than silently skipped."""
    puzzle = _stub_question(
        0,
        question="A man pushes his car to a hotel. What happened?",
        generation_metadata=GenerationProvenance(reasoning_pattern="lateral_thinking"),
    )
    fact_verifier = _FakeFactVerifier(
        {"q_0": VerificationResult(verdict="verified", confidence=0.9)}
    )
    stage = VerificationStage(fact_verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([puzzle])

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    factual_ids = {q["id"] for batch in fact_verifier.calls for q in batch}
    assert factual_ids == {"q_0"}


@pytest.mark.asyncio
async def test_judge_failure_withholds_and_never_counts_as_dropped() -> None:
    """A checker outage must read as "withheld (unverifiable)", never as
    "dropped (proven wrong)".

    Adversarial audit 2026-07-30 found a judge 429/timeout once made both
    real verifier classes return a sub-threshold verdict with
    `held_for_review` unset, so the stage deleted the questions as `dropped`
    — indistinguishable from wrong answers. The real classes must still mark
    the outage as held; since #158 (fail-closed) a held question is withheld
    from the pack rather than kept for review, and the distinct `withheld`
    counter is what keeps the outage legible. Driving the real classes
    through the stage is the point: unit-level holds are worthless if the
    stage misclassifies them. Since #166 increment 2 the factual branch is
    the Claude web fact-check — its outage shape is a raising API call.
    """
    fact_verifier = FactVerifier()

    async def _factcheck_unavailable(prompt: str):
        return None, 0.0

    fact_verifier._call = _factcheck_unavailable  # type: ignore[assignment]
    logical_verifier = LogicalConsistencyVerifier(gemini_api_key="test-key")

    async def _judge_unavailable(prompt: str) -> None:
        return None

    logical_verifier._complete = _judge_unavailable  # type: ignore[assignment]

    factual = _stub_question(0, question="How many people live in X?")
    puzzle = _stub_question(
        1,
        question="A man pushes his car to a hotel. What happened?",
        generation_metadata=GenerationProvenance(reasoning_pattern="lateral_thinking"),
    )
    stage = VerificationStage(fact_verifier, logical_verifier)
    ctx = _make_ctx([factual, puzzle])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert ctx.questions == []
    assert result.info["dropped"] == 0
    assert result.info["withheld"] == 2


@pytest.mark.asyncio
async def test_threshold_default_matches_module_constant() -> None:
    """If the default threshold drifts silently, callers cannot reason about
    the drop policy. Pin it here so a behaviour change is loud."""
    assert DEFAULT_MIN_CONFIDENCE == 0.5


@pytest.mark.asyncio
async def test_lying_lateral_label_still_goes_to_fact_verifier() -> None:
    """#160 (gen-review P4): a question whose generator self-tagged
    `lateral_thinking` but which carries NO server-audited `logical_puzzle`
    marker must be web-verified like any factual question — the label alone
    used to route it past the only truth gate."""
    liar = _stub_question(
        0,
        question="What is the capital of Australia?",
        generation_metadata=GenerationProvenance(
            reasoning_pattern="lateral_thinking"  # label only, no marker
        ),
    )
    fact_verifier = _FakeFactVerifier(
        {"q_0": VerificationResult(verdict="verified", confidence=0.9)}
    )
    logical_verifier = _FakeLogicalVerifier({})
    stage = VerificationStage(fact_verifier, logical_verifier)  # type: ignore[arg-type]
    ctx = _make_ctx([liar])

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert logical_verifier.calls == []
    factual_ids = {q["id"] for batch in fact_verifier.calls for q in batch}
    assert factual_ids == {"q_0"}


@pytest.mark.asyncio
async def test_mcq_options_travel_with_the_stem_to_the_verifier() -> None:
    """An MCQ's answer is the right BUCKET, not an exact measurement.

    "3,800 years" is the correct option for a pyramid that held the record
    for ~3,871 years. Sent as a bare stem plus that claim, the web verifier is
    asked to confirm an exact figure and can drop a correct question as
    `fact_error` — and the inline-option repair sharpens the risk, because the
    options it lifts out of the stem are the very context the verifier used to
    read there. Free-text questions must keep travelling unchanged.
    """
    mcq = _stub_question(
        0,
        question="The Great Pyramid was the tallest structure for how long?",
        type="text_multichoice",
        correct_answer="3,800 years",
        possible_answers={"a": "400 years", "b": "1,400 years", "c": "3,800 years"},
    )
    free_text = _stub_question(1, question="What is the capital of France?")
    fact_verifier = _FakeFactVerifier({})
    stage = VerificationStage(fact_verifier)  # type: ignore[arg-type]

    await stage.run(_make_ctx([mcq, free_text]), sink=_RecordingSink())  # type: ignore[arg-type]

    sent = {q["id"]: q["question"] for batch in fact_verifier.calls for q in batch}
    assert "400 years / 1,400 years / 3,800 years" in sent["q_0"]
    assert sent["q_0"].startswith(
        "The Great Pyramid was the tallest structure for how long?"
    )
    assert sent["q_1"] == "What is the capital of France?"
