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
from app.orchestrator.stages.scoring import (
    JudgePanelUnavailable,
    ScoringStage,
    _shadow_veto_reason,
)
from app.scoring.multi_model_scorer import MultiModelScorer
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
        "q_0": {"gpt-4.1-mini": 8.5, "gemini-2.5-flash": 8.5},
        "q_1": {"gpt-4.1-mini": 7.0, "gemini-2.5-flash": 7.0},
        "q_2": {"gpt-4.1-mini": 6.5, "gemini-2.5-flash": 6.5},
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
async def test_unjudged_question_fails_the_stage() -> None:
    """#147 (founder decision 2026-08-06, supersedes the #42 "unscored → keep"
    rule): the customer must receive judged questions only. One question with
    no judge verdict at all (q_1) is enough to fail the whole stage — it is
    withheld, never delivered, and the order goes back through the retry
    machinery instead of shipping a partly-ungated paid pack."""
    scores = {"q_0": {"gpt-4.1-mini": 9.0, "gemini-2.5-flash": 9.0}}  # q_1 deliberately unjudged
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    with pytest.raises(JudgePanelUnavailable) as exc_info:
        await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert exc_info.value.info["judge_failures"] == 1
    # The unjudged question never survives the stage, whatever happens next.
    assert [q.id for q in ctx.questions] == ["q_0"]


@pytest.mark.asyncio
async def test_drops_question_below_overall_floor() -> None:
    """#42 task 42.29 — fail loud. A question whose mean overall score is below
    MIN_OVERALL_SCORE (3.0) is a catastrophically bad question and must be
    dropped from `ctx.questions`, with the drop surfaced in StageResult.info.
    Before 42.29 the scorers only warned — false confidence that shipped junk."""
    scores = {
        "q_0": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0},  # good — kept
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
        "q_0": {"gpt-4.1-mini": 8.5, "gemini-2.5-flash": 8.5},  # great overall...
        "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0},  # ...also great overall, but bad distractors
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

    assert result.info == {
        "scored": 0,
        "dropped_low_score": 0,
        "judge_failures": 0,
    }
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
    question alongside it is not flagged. VETO_ENFORCE defaults ON since
    2026-08, so it must be explicitly disabled to isolate shadow behaviour."""
    monkeypatch.setenv("VETO_SHADOW", "1")
    monkeypatch.setenv("VETO_ENFORCE", "0")
    scores = {
        "q_0": {"gpt-4.1-mini": 4.0, "gemini-2.5-flash": 4.0},  # clears the 3.0 floor — not score-dropped
        "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0},  # good
    }
    # Per-dimension scorer names (2026-07-30 redesign): answerability is a
    # real scored dimension — q_0 reads as a boring dead-end recall Q.
    dims = {
        "q_0": {"surprise_delight": 2, "answerability": 2},
        "q_1": {"surprise_delight": 8, "answerability": 9},
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
async def test_veto_enforce_drops_flagged_question(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#72 reviewer upgrade: VETO_ENFORCE promotes the veto from logging to
    dropping — the starboard-class question is removed even though it clears
    the lenient overall floor, while the good question survives. Consultation
    is implied: VETO_SHADOW stays unset."""
    monkeypatch.delenv("VETO_SHADOW", raising=False)
    monkeypatch.setenv("VETO_ENFORCE", "1")
    scores = {
        "q_0": {"gpt-4.1-mini": 4.0, "gemini-2.5-flash": 4.0},
        "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0},
    }
    dims = {
        "q_0": {"surprise_delight": 2, "answerability": 2},
        "q_1": {"surprise_delight": 8, "answerability": 9},
    }
    scorer = _FakeMultiModelScorer(scores, dims=dims)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["veto_dropped"] == 1
    assert result.info["veto_shadow_flagged"] == 0
    # Dropped question's scores retained for audit.
    assert "q_0" in ctx.scores


@pytest.mark.asyncio
async def test_veto_enforce_drops_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    """2026-08: VETO_ENFORCE defaults ON (prod parity) — with no env var set
    at all, the starboard-class question is dropped, not just shadow-flagged."""
    monkeypatch.delenv("VETO_SHADOW", raising=False)
    monkeypatch.delenv("VETO_ENFORCE", raising=False)
    scores = {
        "q_0": {"gpt-4.1-mini": 4.0, "gemini-2.5-flash": 4.0},
        "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0},
    }
    dims = {
        "q_0": {"surprise_delight": 2, "answerability": 2},
        "q_1": {"surprise_delight": 8, "answerability": 9},
    }
    scorer = _FakeMultiModelScorer(scores, dims=dims)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["veto_dropped"] == 1


# --- Craft guards in the stage (#72 reviewer upgrade, 2026-07-10) --------------
#
# Why these scenarios: the guards must be shadow-by-default (flag, keep) so the
# pipeline stays byte-identical for output until CRAFT_GUARDS_ENFORCE flips —
# the #72 reversibility contract — and dropping must be exactly flag-gated.


def _leaky_question(idx: int) -> Question:
    """Free-text question whose stem names its own answer (stem_leak)."""
    return _stub_question(
        idx,
        question="Which country's propaganda made Napoleon short, per British archives?",
        correct_answer="Britain",
    )


@pytest.mark.asyncio
async def test_craft_guard_shadow_flags_but_keeps(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CRAFT_GUARDS_ENFORCE defaults ON since 2026-08 (prod parity); shadow
    mode (flag, keep) now requires the explicit rollback value."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "0")
    scores = {"q_0": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}, "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_leaky_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0", "q_1"]
    assert result.info["craft_flagged"] == 1
    assert result.info["craft_dropped"] == 0


@pytest.mark.asyncio
async def test_craft_guard_enforce_drops_stem_leak(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "1")
    scores = {"q_0": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}, "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_leaky_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["craft_dropped"] == 1
    assert result.info["craft_flagged"] == 0


@pytest.mark.asyncio
async def test_craft_guard_enforce_drops_by_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """2026-08: CRAFT_GUARDS_ENFORCE defaults ON (prod parity) — with no env
    var set at all, the stem-leak question is dropped, not just flagged."""
    monkeypatch.delenv("CRAFT_GUARDS_ENFORCE", raising=False)
    scores = {"q_0": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}, "q_1": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_leaky_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["craft_dropped"] == 1


@pytest.mark.asyncio
async def test_craft_guard_enforce_rebalances_all_true_batch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The 94%-True corpus defect, batch-level: five all-True T/F questions →
    the excess beyond the 60% allowance (last two) drop, earlier ones and the
    non-T/F question stay."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "1")
    questions = [
        _stub_question(
            i,
            question=f"True or false: surprising fact number {i}?",
            correct_answer="True",
        )
        for i in range(5)
    ] + [_stub_question(5)]
    scores = {q.id: {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0} for q in questions}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx(questions)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0", "q_1", "q_2", "q_5"]
    assert result.info["craft_dropped"] == 2


@pytest.mark.asyncio
async def test_craft_guard_enforce_drops_imperial_units(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#99 D3 (G3 Q7): the units guard rides the same CRAFT_GUARDS_ENFORCE
    gate as the other craft guards — an imperial-only figure drops."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "1")
    questions = [
        _stub_question(
            0,
            question="England recorded what temperature milestone in 2022?",
            correct_answer="100 degrees Fahrenheit",
        ),
        _stub_question(1),
    ]
    scores = {q.id: {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0} for q in questions}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx(questions)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["craft_dropped"] == 1


@pytest.mark.asyncio
async def test_undated_record_is_shadow_only_even_under_enforce(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#99 D2-subset contract: the undated-record heuristic counts and logs
    but must NEVER drop — not even under CRAFT_GUARDS_ENFORCE — until it is
    validated on a founder-rated batch (it has known FP shapes)."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "1")
    questions = [
        _stub_question(
            0,
            question="For the first time ever, which country banned "
            "commercial whaling outright?",
            correct_answer="Norway",
        ),
        _stub_question(1),
    ]
    scores = {q.id: {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0} for q in questions}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx(questions)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0", "q_1"]
    assert result.info["undated_shadow_flagged"] == 1
    assert result.info["craft_dropped"] == 0


# --- Judge-panel outage: FAIL CLOSED (#147, founder decision 2026-08-06) ------
#
# Why these scenarios: when every judge failed, the scorer used to hand the gate
# a synthetic entry whose "overall score" was `answer_brevity` — a word count.
# The gate averaged it like a verdict, so a provider outage silently swapped the
# pipeline's only quality gate for "is the answer short?": brevity 7/10 cleared
# the 3.0 floor (ungated paid pack ships), brevity 1 dropped (mass-drop for a
# reason no step log explained). These tests pin that answer length can no
# longer decide anything, and that the outage is loud instead of silent.


_SHORT_ANSWER = "Paris"  # answer_brevity 10 — used to sail through the gate
_LONG_ANSWER = (  # answer_brevity 1 — over the word cap AND an explanation tail
    "Basketball — its rules were written by James Naismith in December 1891, "
    "while the modern marathon distance was only standardised at the 1908 "
    "London Olympics"
)


def _dead_panel_scorer() -> MultiModelScorer:
    """A real MultiModelScorer with no judge left — the outage shape itself.

    Deliberately the production object rather than a double: the thing under
    test is what `score_question` emits when every judge fails, so a stubbed
    "outage" entry would test the stub.
    """
    scorer = MultiModelScorer(models=[{"provider": "openai", "model": "x", "name": "x"}])
    scorer.models = []
    return scorer


@pytest.mark.asyncio
async def test_total_panel_failure_is_length_blind_and_fails_the_stage(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The core #147 regression: under a total panel outage, a brevity-10 and a
    brevity-1 question get IDENTICAL outcomes — both withheld, the stage fails.
    Before the fix the short one shipped ungated and the long one was dropped.

    Craft enforcement is pinned off so answer length has exactly one possible
    route into the outcome (the judge gate) — with it on, the long answer would
    also trip the deterministic long-answer guard and blur the comparison."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "0")
    monkeypatch.setenv("VETO_ENFORCE", "0")
    stage = ScoringStage(_dead_panel_scorer())
    ctx = _make_ctx([
        _stub_question(0, correct_answer=_SHORT_ANSWER),
        _stub_question(1, correct_answer=_LONG_ANSWER),
    ])

    with pytest.raises(JudgePanelUnavailable) as exc_info:
        await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    # Identical outcome for both: neither is delivered.
    assert ctx.questions == []
    assert exc_info.value.info["judge_failures"] == 2
    assert exc_info.value.info["dropped_low_score"] == 0  # nothing was "judged bad"


def test_gate_reason_ignores_the_judge_failure_entry() -> None:
    """The deterministic entry can no longer produce OR clear a gate verdict:
    `_gate_reason` sees no overall at all for it, whatever the word count. This
    is the invariant the old docstring claimed and the code contradicted."""
    from app.scoring.multi_model_scorer import compute_answer_brevity

    for answer in (_SHORT_ANSWER, _LONG_ANSWER):
        entry = {
            "model_name": "deterministic",
            "scores": {"answer_brevity": compute_answer_brevity(answer)},
            "overall_score": None,
            "judge_failed": True,
        }
        assert ScoringStage._gate_reason([entry]) is None, answer


@pytest.mark.asyncio
async def test_healthy_run_reports_zero_judge_failures() -> None:
    """The counter must be trustworthy in both directions — a healthy panel
    reports 0, so a non-zero value in an order's step log always means the
    judges were actually down."""
    scores = {"q_0": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 8.0}, "q_1": {"gpt-4.1-mini": 4.0, "gemini-2.5-flash": 4.0}}
    stage = ScoringStage(_FakeMultiModelScorer(scores))  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0), _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info["judge_failures"] == 0
    assert [q.id for q in ctx.questions] == ["q_0", "q_1"]


@pytest.mark.asyncio
async def test_judge_outage_is_reported_to_sentry(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A late pack for a paying customer caused by an upstream outage must page
    us: the step-log counter alone is only read after someone goes looking."""
    import sentry_sdk

    captured: list[tuple[str, str]] = []
    monkeypatch.setattr(
        sentry_sdk,
        "capture_message",
        lambda message, level=None, **kw: captured.append((message, level)),
    )
    stage = ScoringStage(_dead_panel_scorer())
    ctx = _make_ctx([_stub_question(0, correct_answer=_SHORT_ANSWER)])

    with pytest.raises(JudgePanelUnavailable):
        await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(captured) == 1
    message, level = captured[0]
    assert level == "error"
    assert str(ctx.order_id) in message


@pytest.mark.asyncio
async def test_veto_dormant_when_flag_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """VETO_ENFORCE defaults ON since 2026-08 (prod parity), so "veto not
    consulted at all" now requires explicitly disabling it (the old dormant
    behaviour becomes the rollback path, not the default)."""
    monkeypatch.delenv("VETO_SHADOW", raising=False)
    monkeypatch.setenv("VETO_ENFORCE", "0")
    scores = {"q_0": {"gpt-4.1-mini": 4.0, "gemini-2.5-flash": 4.0}}
    dims = {"q_0": {"surprise_delight": 2, "clever_framing": 2}}
    scorer = _FakeMultiModelScorer(scores, dims=dims)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["veto_shadow_flagged"] == 0


@pytest.mark.asyncio
async def test_single_judge_verdict_fails_the_quorum() -> None:
    """#159 (gen-review P4): #147 closed the 0-judge hole; this closes the
    1-of-3 one. A single (possibly skewed) judge is not a panel — a question
    with only one real verdict is withheld and the stage fails through the
    same #147 retry machinery instead of letting one judge ship it."""
    scores = {"q_0": {"gpt-4.1-mini": 9.0}}  # one real verdict — below quorum
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    with pytest.raises(JudgePanelUnavailable) as exc_info:
        await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert exc_info.value.info["judge_failures"] == 1
    assert ctx.questions == []


@pytest.mark.asyncio
async def test_two_judge_verdicts_meet_the_quorum() -> None:
    """#159: two of three judges responding is a functioning panel — the
    question passes on their mean and the run reports no judge failures."""
    scores = {"q_0": {"gpt-4.1-mini": 8.0, "gemini-2.5-flash": 7.0}}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["judge_failures"] == 0


@pytest.mark.asyncio
async def test_judge_quorum_env_is_the_rollback_lever(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#159: JUDGE_QUORUM=1 restores the pre-#159 single-judge gate — the
    rollback path must actually work, or the quorum can't ship safely."""
    monkeypatch.setenv("JUDGE_QUORUM", "1")
    scores = {"q_0": {"gpt-4.1-mini": 8.0}}
    scorer = _FakeMultiModelScorer(scores)
    stage = ScoringStage(scorer)  # type: ignore[arg-type]
    ctx = _make_ctx([_stub_question(0)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["judge_failures"] == 0


# --- #166 D21b — judges-off mode (scorer=None) --------------------------------
# Founder 2026-08-24: the LLM judge panel leaves the default flow (on D21b data
# it predicted neither fun nor factuality — Spearman ≤ .21, recall 0/6). The
# stage must keep its deterministic gates without a single judge call, and the
# #147/#159 fail-closed machinery must not fire (there is no panel to be
# unavailable).


@pytest.mark.asyncio
async def test_no_judges_keeps_questions_without_scoring() -> None:
    """scorer=None delivers the batch without judge calls, empty ctx.scores —
    CompositionStage then falls back to generation order (its documented
    judges-off behaviour)."""
    stage = ScoringStage(None)
    ctx = _make_ctx([_stub_question(i) for i in range(3)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0", "q_1", "q_2"]
    assert ctx.scores == {}
    assert result.info["scored"] == 0
    assert result.info["judge_failures"] == 0


@pytest.mark.asyncio
async def test_no_judges_never_raises_judge_panel_unavailable() -> None:
    """Without a panel there is no quorum to miss: the #147/#159 fail-closed
    path must stay silent, or every judges-off order would fail permanently."""
    stage = ScoringStage(None)
    ctx = _make_ctx([_stub_question(0)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info["judge_failures"] == 0
    assert len(ctx.questions) == 1


@pytest.mark.asyncio
async def test_no_judges_still_enforces_craft_guards(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Removing the judges must NOT remove the deterministic craft guards —
    they are founder-calibrated rules (#72), not judge output. A stem that
    leaks its own answer still drops."""
    monkeypatch.delenv("CRAFT_GUARDS_ENFORCE", raising=False)
    stage = ScoringStage(None)
    leaky = _stub_question(
        0,
        question="Is the answer to this question simply the word answer?",
        correct_answer="answer",
    )
    ctx = _make_ctx([leaky, _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["craft_dropped"] == 1


@pytest.mark.asyncio
async def test_no_judges_still_drops_low_distractor_quality() -> None:
    """The distractor gate is deterministic (#42 task 42.6) — in judge mode it
    rides on the panel's score dicts, so with the panel gone the stage must
    compute it directly. A duplicate-distractor MCQ still drops."""
    stage = ScoringStage(None)
    broken_mcq = _stub_question(
        0,
        question="Which planet is known as the red planet?",
        correct_answer="Mars",
        possible_answers={"a": "Mars", "b": "Venus", "c": "Venus", "d": "Venus"},
        type="text_multichoice",
    )
    ctx = _make_ctx([broken_mcq, _stub_question(1)])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["dropped_low_score"] == 1
