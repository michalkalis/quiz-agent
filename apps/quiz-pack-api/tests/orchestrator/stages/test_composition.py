"""Unit tests for CompositionStage (#153 Phase 0.1).

Why these scenarios:

- `test_topic_cap_drops_excess`: the 2026-08-07 rated batch carried ~13
  questions on one theme in a 27-question pack — per-question quality gates
  cannot see monotony, so the batch-level cap is the only defence. A topic
  beyond the cap must lose its excess questions.
- `test_topic_cap_keeps_best_judge_scores`: when judge scores exist, the cap
  must keep each topic's best-rated questions, not the first-generated ones
  — otherwise the cap actively lowers pack quality while fixing monotony.
- `test_tf_cap_drops_excess_true_false`: 6 of 8 MCQs in the rated batch were
  T/F; founder wants T/F rare (~2 per 30). Both MCQ-shaped and free-text T/F
  count against the cap.
- `test_caps_scale_with_target_count`: caps are "per 30" rules — a
  10-question pack must not inherit the absolute 30-pack allowance.
- `test_unscored_batch_keeps_generation_order`: judges-off experiment runs
  (#153 Phase A) have no scores; the stage must stay deterministic (first
  generated wins within a cap) and never reorder survivors.
- `TestPerTopicCapOverride`: #167 — the scaled cap assumes ~target/2 sourced
  topics. A locked 6-theme pilot at target 30 could compose at most 12
  questions, and the top-up loop re-ran the paid judge/verify/score pipeline
  chasing the unreachable remainder. The override must lift exactly that cap
  and nothing else, and its absence must leave the scaled cap untouched.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.composition import CompositionStage


class _NullSink:
    async def start_step(self, step, info=None):
        return 0

    async def finish_step(self, step, event_id, info=None):
        pass

    async def publish(self, event_id, step, progress, info=None):
        pass


def _question(idx: int, topic: str = "General", **overrides: Any):
    from quiz_shared.models.question import Question

    base: dict[str, Any] = dict(
        id=f"q_{idx}",
        question=f"distinct stub question number {idx}",
        correct_answer=f"answer {idx}",
        topic=topic,
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _ctx(questions, target_count: int) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="general knowledge",
        language="en",
        target_count=target_count,
    )
    ctx.questions = list(questions)
    return ctx


@pytest.mark.asyncio
async def test_topic_cap_drops_excess():
    questions = [
        _question(1, topic="Jazz History"),
        _question(2, topic="Jazz History"),
        _question(3, topic="Jazz History"),
        _question(4, topic="Space"),
    ]
    ctx = _ctx(questions, target_count=30)

    result = await CompositionStage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_1", "q_2", "q_4"]
    assert result.info["topic_cap"] == 2
    assert result.info["topic_cap_dropped"] == 1


@pytest.mark.asyncio
async def test_topic_cap_keeps_best_judge_scores():
    questions = [
        _question(1, topic="Jazz"),
        _question(2, topic="Jazz"),
        _question(3, topic="Jazz"),
    ]
    ctx = _ctx(questions, target_count=30)
    ctx.scores = {
        "q_1": {"judge-a": 4.0},
        "q_2": {"judge-a": 9.0},
        "q_3": {"judge-a": 8.0},
    }

    await CompositionStage().run(ctx, _NullSink())

    # The two best-scored survive; original relative order is preserved.
    assert [q.id for q in ctx.questions] == ["q_2", "q_3"]


@pytest.mark.asyncio
async def test_tf_cap_drops_excess_true_false():
    tf_options = {"a": "True", "b": "False"}
    questions = [
        _question(1, topic="T1", possible_answers=tf_options, correct_answer="a"),
        _question(2, topic="T2", correct_answer="True"),
        _question(3, topic="T3", possible_answers=tf_options, correct_answer="b"),
        _question(4, topic="T4"),
    ]
    ctx = _ctx(questions, target_count=30)

    result = await CompositionStage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_1", "q_2", "q_4"]
    assert result.info["tf_cap"] == 2
    assert result.info["tf_cap_dropped"] == 1


@pytest.mark.asyncio
async def test_caps_scale_with_target_count():
    tf_options = {"a": "True", "b": "False"}
    questions = [
        _question(1, topic="Jazz"),
        _question(2, topic="Jazz"),
        _question(3, topic="Jazz"),
        _question(4, topic="T1", possible_answers=tf_options, correct_answer="a"),
        _question(5, topic="T2", possible_answers=tf_options, correct_answer="b"),
    ]
    ctx = _ctx(questions, target_count=10)

    result = await CompositionStage().run(ctx, _NullSink())

    # Topic cap keeps its floor of 2 on a 10-pack (topic sampling yields
    # ~5 topics there — cap 1 would guarantee a shortfall); the T/F cap has
    # no shortfall risk and scales down: ceil(2 * 10 / 30) = 1.
    assert result.info["topic_cap"] == 2
    assert result.info["tf_cap"] == 1
    assert [q.id for q in ctx.questions] == ["q_1", "q_2", "q_4"]


@pytest.mark.asyncio
async def test_unscored_batch_keeps_generation_order():
    questions = [_question(i, topic=f"T{i}") for i in range(1, 6)]
    ctx = _ctx(questions, target_count=30)

    result = await CompositionStage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == [f"q_{i}" for i in range(1, 6)]
    assert result.info["topic_cap_dropped"] == 0
    assert result.info["tf_cap_dropped"] == 0


class TestPerTopicCapOverride:
    """#167 — the per-run per-topic cap override."""

    @pytest.mark.asyncio
    async def test_default_none_keeps_scaled_cap(self):
        """No override → the 2-per-30 rule still binds, byte-identical to
        pre-#167 behaviour. This is the regression guard for the worker/API
        path, which constructs `CompositionStage()` with no arguments."""
        questions = [_question(i, topic="Jazz History") for i in range(1, 5)]
        ctx = _ctx(questions, target_count=30)

        result = await CompositionStage().run(ctx, _NullSink())

        assert result.info["topic_cap"] == 2
        assert [q.id for q in ctx.questions] == ["q_1", "q_2"]

    @pytest.mark.asyncio
    async def test_override_lets_six_locked_topics_reach_a_30_target(self):
        """The pilot's actual shape: 6 locked themes, target 30. Under the
        scaled cap of 2 only 12 questions can survive — the shortfall is
        arithmetically unfixable, which is what sent the top-up loop through
        the paid pipeline repeatedly. With `per_topic_cap=5` all 30 survive,
        so top-up never runs."""
        questions = [
            _question(idx, topic=f"Theme {theme}")
            for idx, theme in enumerate(
                (t for t in range(1, 7) for _ in range(5)), start=1
            )
        ]
        ctx = _ctx(questions, target_count=30)

        result = await CompositionStage(per_topic_cap=5).run(ctx, _NullSink())

        assert result.info["topic_cap"] == 5
        assert result.info["topic_cap_dropped"] == 0
        assert len(ctx.questions) == 30

    @pytest.mark.asyncio
    async def test_override_still_binds_beyond_its_own_limit(self):
        """The override raises the cap, it does not disable it — a 7th
        question on a theme is still dropped at `per_topic_cap=5`."""
        questions = [_question(i, topic="Theme 1") for i in range(1, 8)]
        ctx = _ctx(questions, target_count=30)

        result = await CompositionStage(per_topic_cap=5).run(ctx, _NullSink())

        assert [q.id for q in ctx.questions] == [f"q_{i}" for i in range(1, 6)]
        assert result.info["topic_cap_dropped"] == 2

    @pytest.mark.asyncio
    async def test_override_does_not_touch_the_tf_cap(self):
        """Lifting the topic cap must not smuggle in a T/F flood — the
        founder's "T/F stays a rarity" rule is a separate axis."""
        tf_options = {"a": "True", "b": "False"}
        questions = [
            _question(i, topic="Theme 1", possible_answers=tf_options, correct_answer="a")
            for i in range(1, 5)
        ]
        ctx = _ctx(questions, target_count=30)

        result = await CompositionStage(per_topic_cap=5).run(ctx, _NullSink())

        assert result.info["tf_cap"] == 2
        assert result.info["tf_cap_dropped"] == 2
        assert [q.id for q in ctx.questions] == ["q_1", "q_2"]
