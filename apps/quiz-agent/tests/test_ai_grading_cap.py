"""#218.7: daily per-player cap on AI answer gradings.

Why: the LLM judge is a paid call per free-text answer; a looping client or a
stolen identity would spend shared credit without bound. Founder decision: a
player past the cap is NOT blocked (no 429, no service-wide cap): answers fall
back to the fast deterministic path, and the founder gets at most one mail a day.
"""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock

import pytest
from app.config import get_settings
from app.usage import ai_grading_cap
from app.usage.ai_grading_cap import ai_grading_stats, bind_ai_grading
from app.usage.caps import UsageCaps
from quiz_shared.models.question import Question

os.environ.setdefault("OPENAI_API_KEY", "sk-test")
pytestmark = pytest.mark.asyncio

_T0 = datetime(2026, 11, 2, 23, 0, tzinfo=UTC)


def _question() -> Question:
    return Question(
        id="q1",
        question="Capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geo",
        category="adults",
        difficulty="easy",
    )


@pytest.fixture
def setup(db_sessionmaker, monkeypatch):
    monkeypatch.setattr(get_settings(), "daily_cap_ai_gradings", 2)
    mails: list[str] = []

    async def fake_mail(subject, body):
        mails.append(subject)
        return True

    monkeypatch.setattr(ai_grading_cap, "send_email_async", fake_mail)
    now = [_T0]
    caps = UsageCaps(db_sessionmaker, now=lambda: now[0])

    from app.evaluation.evaluator import AnswerEvaluator

    evaluator = AnswerEvaluator()
    evaluator._llm_evaluate = AsyncMock(return_value="correct")
    return evaluator, caps, now, mails


async def test_past_the_cap_no_paid_call_but_exact_answer_still_counts(setup):
    evaluator, caps, _, _ = setup
    bind_ai_grading(caps, "u1")
    for _ in range(2):  # within the cap: the LLM judges
        verdict = await evaluator.evaluate("the city of lights", _question())
        assert verdict == ("correct", 1.0)
    assert evaluator._llm_evaluate.await_count == 2

    verdict = await evaluator.evaluate("something vague", _question())
    assert verdict == ("incorrect", 0.0)
    assert evaluator._llm_evaluate.await_count == 2  # no third paid call
    # the fast path is untouched by the cap
    assert await evaluator.evaluate("paris", _question()) == ("correct", 1.0)


async def test_cap_is_per_player_and_resets_each_utc_day(setup):
    evaluator, caps, now, _ = setup
    bind_ai_grading(caps, "heavy")
    for _ in range(3):
        await evaluator.evaluate("nope", _question())
    assert evaluator._llm_evaluate.await_count == 2

    bind_ai_grading(caps, "friend")  # another player is unaffected
    await evaluator.evaluate("nope", _question())
    assert evaluator._llm_evaluate.await_count == 3

    now[0] = _T0 + timedelta(hours=2)  # past UTC midnight
    bind_ai_grading(caps, "heavy")
    await evaluator.evaluate("nope", _question())
    assert evaluator._llm_evaluate.await_count == 4


async def test_one_mail_per_day_however_many_players_hit_it(setup):
    evaluator, caps, now, mails = setup
    for player in ("a", "b"):
        bind_ai_grading(caps, player)
        for _ in range(4):
            await evaluator.evaluate("nope", _question())
    assert len(mails) == 1
    assert await ai_grading_stats(caps) == (2, 4)  # 2 capped players, 4 gradings

    now[0] = _T0 + timedelta(hours=2)
    bind_ai_grading(caps, "a")
    for _ in range(3):
        await evaluator.evaluate("nope", _question())
    assert len(mails) == 2  # a new day may mail again


async def test_unbound_calls_are_never_capped(setup):
    evaluator, _, _, _ = setup
    bind_ai_grading(UsageCaps(None), None)  # evals/scripts: no subject
    for _ in range(5):
        await evaluator.evaluate("nope", _question())
    assert evaluator._llm_evaluate.await_count == 5
