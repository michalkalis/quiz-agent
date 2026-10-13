"""#201 — the casual-player check inside ScoringStage.

Why this matters: founder 2026-10-13 — fresh entertainment questions were
"almost without a chance to know the answer", and a quarter of the rest were
only easy because the stem gave the answer away. The check must (1) drop both
kinds when on, (2) only record in shadow mode, so the blind comparison can
rate would-drops vs passes, (3) never touch other categories or run when off,
and (4) fail OPEN — a checker outage must not withhold a question or trip the
fail-closed judge-outage path (#147).
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from app.orchestrator import OrderContext
from app.orchestrator.stages.scoring import ScoringStage
from app.verification.casual_player import (
    VERDICT_KEY,
    CasualPlayerChecker,
)
from quiz_shared.models.question import Question


class _Sink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        return None

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        return None


def _checker(replies: dict[str, str | None]) -> CasualPlayerChecker:
    """Canned raw model replies keyed by a substring of the question text."""
    checker = CasualPlayerChecker(model="stub-model")
    checker.calls = 0  # type: ignore[attr-defined]

    async def _complete(prompt: str) -> str | None:
        checker.calls += 1  # type: ignore[attr-defined]
        for needle, reply in replies.items():
            if needle in prompt:
                return reply
        return None

    checker._complete = _complete  # type: ignore[method-assign]
    return checker


def _reply(pct: int, giveaway: bool = False) -> str:
    return f'{{"casual_correct_pct": {pct}, "giveaway": {str(giveaway).lower()}, "reason": "r"}}'


def _question(idx: int, text: str, category: str = "entertainment") -> Question:
    return Question(
        id=f"q_{idx}",
        question=text,
        correct_answer="answer",
        topic="Film",
        category=category,
        difficulty="medium",
        source_excerpt="evidence",
    )


def _ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="fresh entertainment",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


def _batch() -> list[Question]:
    return [
        _question(0, "FAIR which film"),
        _question(1, "LEAK the actor who played Kylo Ren"),
        _question(2, "NICHE which supporting nominee"),
    ]


_REPLIES = {"FAIR": _reply(70), "LEAK": _reply(95, giveaway=True), "NICHE": _reply(5)}


@pytest.mark.asyncio
async def test_on_drops_giveaways_and_no_chance_questions(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("CASUAL_PLAYER_GATE", "1")
    ctx = _ctx(_batch())

    result = await ScoringStage(None, casual_checker=_checker(_REPLIES)).run(
        ctx, sink=_Sink()  # type: ignore[arg-type]
    )

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["casual_dropped"] == 2
    assert ctx.questions[0].generation_metadata.extra[VERDICT_KEY]["pct"] == 70


@pytest.mark.asyncio
async def test_shadow_keeps_everything_but_records_would_drops(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Shadow is the 201.4 ablation: the would-drop rows must be rateable."""
    monkeypatch.setenv("CASUAL_PLAYER_GATE", "shadow")
    ctx = _ctx(_batch())

    result = await ScoringStage(None, casual_checker=_checker(_REPLIES)).run(
        ctx, sink=_Sink()  # type: ignore[arg-type]
    )

    assert len(ctx.questions) == 3
    assert result.info["casual_flagged"] == 2
    verdicts = {q.id: q.generation_metadata.extra[VERDICT_KEY] for q in ctx.questions}
    assert verdicts["q_0"]["would_drop"] is None
    assert verdicts["q_1"]["would_drop"] == "giveaway"
    assert verdicts["q_2"]["would_drop"] == "casual_below_25"
    assert verdicts["q_2"]["excerpt_missing"] is False


@pytest.mark.asyncio
async def test_off_by_default_makes_no_calls(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CASUAL_PLAYER_GATE", raising=False)
    checker = _checker(_REPLIES)
    ctx = _ctx(_batch())

    await ScoringStage(None, casual_checker=checker).run(ctx, sink=_Sink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 3
    assert checker.calls == 0  # type: ignore[attr-defined]
    assert all(
        VERDICT_KEY not in (q.generation_metadata.extra if q.generation_metadata else {})
        for q in ctx.questions
    )


@pytest.mark.asyncio
async def test_other_categories_are_not_checked(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CASUAL_PLAYER_GATE", "1")
    checker = _checker(_REPLIES)
    ctx = _ctx([_question(0, "NICHE science fact", category="science")])

    await ScoringStage(None, casual_checker=checker).run(ctx, sink=_Sink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 1
    assert checker.calls == 0  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_checker_outage_keeps_the_question_even_with_judges_on(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Fail-open: an exploding checker must not withhold or raise
    JudgePanelUnavailable — that path is reserved for judge outages."""
    monkeypatch.setenv("CASUAL_PLAYER_GATE", "1")
    checker = CasualPlayerChecker(model="stub-model")

    async def _boom(q: Question, floor: int):
        raise RuntimeError("provider down")

    checker.check = _boom  # type: ignore[method-assign]

    class _Scorer:
        async def score_batch(self, questions, sql_client=None):
            return [
                {
                    "id": q["id"],
                    "model_scores": [
                        {"model_name": m, "scores": {}, "overall_score": 8.0}
                        for m in ("a", "b")
                    ],
                }
                for q in questions
            ]

    ctx = _ctx([_question(0, "FAIR which film")])
    result = await ScoringStage(_Scorer(), casual_checker=checker).run(  # type: ignore[arg-type]
        ctx, sink=_Sink()  # type: ignore[arg-type]
    )

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["judge_failures"] == 0
