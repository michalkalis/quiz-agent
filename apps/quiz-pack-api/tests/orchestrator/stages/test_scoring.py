"""Unit tests for ScoringStage (issue #36 task 2.7).

Why these scenarios:

- `test_scores_keyed_by_question_id`: downstream review tooling joins
  per-question scores back onto question rows by id. If the stage keys
  by index or name, the join silently produces empty score columns for
  every question — a regression that would not be caught by a smoke
  test that only counts dict entries.
- `test_does_not_drop_questions`: the Phase 2 drop policy lives in
  `VerificationStage`. ScoringStage explicitly stays side-effect-free
  on `ctx.questions` so Phase 3 (#37) can layer drop-by-score on top
  without untangling double-filtering.
- `test_multiple_models_recorded_per_question`: A/B scoring depends on
  having one entry per `model_name` so we can correlate which model
  best predicts user ratings (see MultiModelScorer docstring). A stage
  that flattened to a single overall score would break the A/B
  analysis silently.
- `test_no_questions_returns_zero_count`: empty input is the happy
  no-op path — proves the stage does not crash when an upstream stage
  drained the pack (e.g. verification dropped everything).
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.scoring import ScoringStage, _shadow_veto_reason
from quiz_shared.models.question import Question


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


class _FakeMultiModelScorer:
    """MultiModelScorer double that returns canned per-model scores.

    Caller passes a {question_id: {model_name: overall_score}} map.
    Questions without a mapped entry get an empty `model_scores` list.

    `dims` (optional, #42 task 42.29) maps {question_id: {dim: value}} extra
    score dimensions (e.g. `distractor_quality`) merged into every model's
    `scores` sub-dict — mirroring how `MultiModelScorer` attaches the
    deterministic dims from task 42.6 — so drop-gate tests can exercise the
    MCQ branch.
    """

    def __init__(
        self,
        scores: dict[str, dict[str, float]],
        dims: dict[str, dict[str, float]] | None = None,
    ) -> None:
        self._scores = scores
        self._dims = dims or {}
        self.calls: list[list[dict[str, Any]]] = []

    async def score_batch(
        self, questions: list[dict[str, Any]], sql_client: Any = None
    ) -> list[dict[str, Any]]:
        self.calls.append(questions)
        out: list[dict[str, Any]] = []
        for q in questions:
            qid = q["id"]
            per_model = self._scores.get(qid, {})
            extra_dims = self._dims.get(qid, {})
            out.append(
                {
                    "id": qid,
                    "model_scores": [
                        {
                            "model_name": name,
                            "scores": {"conversation_spark": 8, **extra_dims},
                            "overall_score": overall,
                        }
                        for name, overall in per_model.items()
                    ],
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
async def test_scores_keyed_by_question_id() -> None:
    scores = {
        "q_0": {"gpt-4.1-mini": 8.5},
        "q_1": {"gpt-4.1-mini": 7.0},
        "q_2": {"gpt-4.1-mini": 6.5},
    }
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(i) for i in range(3)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert set(ctx.scores.keys()) == {"q_0", "q_1", "q_2"}
    assert ctx.scores["q_0"]["gpt-4.1-mini"] == pytest.approx(8.5)
    assert ctx.scores["q_1"]["gpt-4.1-mini"] == pytest.approx(7.0)
    assert result.info["scored"] == 3


@pytest.mark.asyncio
async def test_keeps_passing_and_unscored_questions() -> None:
    """#42 task 42.29 — the gate drops only on a *bad* judgment, never on the
    *absence* of one. A well-scored question (q_0) and a question the scorer
    could not score at all (q_1, empty model_scores) must both survive: we do
    not throw away questions just because the scorer was silent on them."""
    scores = {"q_0": {"gpt-4.1-mini": 9.0}}  # q_1 deliberately unscored
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])
    before_ids = [q.id for q in ctx.questions]

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == before_ids
    assert result.info["dropped_low_score"] == 0


@pytest.mark.asyncio
async def test_drops_question_below_overall_floor() -> None:
    """#42 task 42.29 — fail loud. A question whose mean overall score is below
    MIN_OVERALL_SCORE (3.0) is a catastrophically bad question and must be
    dropped from `ctx.questions`, with the drop surfaced in StageResult.info.
    Before 42.29 the scorers only warned — false confidence that shipped junk."""
    scores = {
        "q_0": {"gpt-4.1-mini": 8.0},  # good — kept
        "q_1": {"gpt-4.1-mini": 2.0, "claude-sonnet-4.6": 2.5},  # mean 2.25 — dropped
    }
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["dropped_low_score"] == 1
    # Dropped question's scores are retained for audit ("why did it fail?").
    assert "q_1" in ctx.scores


@pytest.mark.asyncio
async def test_drops_mcq_with_low_distractor_quality() -> None:
    """#42 task 42.29 — the MCQ-specific gate. An MCQ with a strong overall
    score but broken distractors (duplicate / substring-leak / length-skew →
    distractor_quality below MIN_DISTRACTOR_QUALITY, 4) must still be dropped.
    This is the dim that catches give-away options no overall score reflects."""
    scores = {
        "q_0": {"gpt-4.1-mini": 8.5},  # great overall...
        "q_1": {"gpt-4.1-mini": 8.0},  # ...also great overall, but bad distractors
    }
    dims = {"q_1": {"distractor_quality": 2}}  # below the floor of 4
    scorer = _FakeMultiModelScorer(scores, dims=dims)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["dropped_low_score"] == 1


@pytest.mark.asyncio
async def test_multiple_models_recorded_per_question() -> None:
    scores = {
        "q_0": {"gpt-4.1-mini": 8.0, "claude-sonnet-4.6": 8.5},
    }
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    per_model = ctx.scores["q_0"]
    assert set(per_model.keys()) == {"gpt-4.1-mini", "claude-sonnet-4.6"}
    assert per_model["gpt-4.1-mini"] == pytest.approx(8.0)
    assert per_model["claude-sonnet-4.6"] == pytest.approx(8.5)


@pytest.mark.asyncio
async def test_no_questions_returns_zero_count() -> None:
    scorer = _FakeMultiModelScorer({})
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info == {"scored": 0, "dropped_low_score": 0}
    assert ctx.scores == {}
    assert scorer.calls == []


# --- Answerability/surprise veto, SHADOW (issue #72 P4.1) ---------------------
#
# Why these scenarios: the veto is the one place fun is *enforced* in the
# plumbing. If it fired on good questions it would be worse than useless (it
# would teach us to ignore it), so every test pins both halves of the gate —
# the starboard-class recall question is flagged AND the good ones are not.


def _scored(dims: dict[str, float], *, names=("gpt-4.1-mini",)) -> list[dict]:
    """Build a model_scores list with `dims` attached to every model's scores."""
    return [
        {"model_name": n, "scores": dict(dims), "overall_score": 5.0} for n in names
    ]


def test_shadow_veto_reason_flags_starboard_class_recall() -> None:
    """The "What do sailors call the right side? → Starboard" archetype: a pure
    dead-end recall question (critique_v2 "Poor 3-4" anchor — surprise 2 /
    answerability 2) is flagged. A genuinely fun question, the "Average 5-6
    meets minimum bar" anchor, and a surprising-but-dead-end question are NOT —
    proving the AND threshold keeps false vetoes at zero."""
    # Starboard-class — flagged (reads the critique_v2 alias names).
    assert _shadow_veto_reason(
        _scored({"surprise_factor": 2, "answerability": 2})
    ) is not None
    # Exceptional fun question — never flagged.
    assert _shadow_veto_reason(
        _scored({"surprise_factor": 9, "answerability": 8})
    ) is None
    # "Average — meets minimum bar" (octopus-hearts anchor): surprise 5 clears
    # the line, so it is kept even though framing is weak.
    assert _shadow_veto_reason(
        _scored({"surprise_factor": 5, "answerability": 4})
    ) is None
    # Surprising but somewhat dead-end → kept (AND, not OR: one low signal is
    # not enough to veto a question that still delivers an "aha").
    assert _shadow_veto_reason(
        _scored({"surprise_factor": 8, "answerability": 2})
    ) is None
    # No surprise/answerability scored at all → never veto on absent judgment.
    assert _shadow_veto_reason(_scored({"conversation_spark": 2})) is None
    assert _shadow_veto_reason([]) is None


@pytest.mark.asyncio
async def test_veto_shadow_flags_starboard_class_but_keeps_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Gate for P4.1: with VETO_SHADOW on, a starboard-class recall question
    that clears the lenient overall floor is FLAGGED (surfaced in info) yet
    still KEPT — shadow mode logs would-drops, drops nothing — while a good
    question alongside it is not flagged."""
    monkeypatch.setenv("VETO_SHADOW", "1")
    scores = {
        "q_0": {"gpt-4.1-mini": 4.0},  # clears the 3.0 floor — not score-dropped
        "q_1": {"gpt-4.1-mini": 8.0},  # good
    }
    # Live SCORING_PROMPT alias names — q_0 reads as a boring dead-end recall Q.
    dims = {
        "q_0": {"surprise_delight": 2, "clever_framing": 2},
        "q_1": {"surprise_delight": 8, "clever_framing": 9},
    }
    scorer = _FakeMultiModelScorer(scores, dims=dims)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    # Shadow: NOTHING dropped — both questions survive.
    assert [q.id for q in ctx.questions] == ["q_0", "q_1"]
    assert result.info["dropped_low_score"] == 0
    # ...but exactly the starboard-class one is flagged.
    assert result.info["veto_shadow_flagged"] == 1


@pytest.mark.asyncio
async def test_veto_dormant_when_flag_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """Default (flag off): the veto is not consulted at all — a starboard-class
    question produces zero flags, so the change is dormant until Phase 6."""
    monkeypatch.delenv("VETO_SHADOW", raising=False)
    scores = {"q_0": {"gpt-4.1-mini": 4.0}}
    dims = {"q_0": {"surprise_delight": 2, "clever_framing": 2}}
    scorer = _FakeMultiModelScorer(scores, dims=dims)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["veto_shadow_flagged"] == 0
