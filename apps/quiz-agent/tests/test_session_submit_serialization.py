"""Adversarial audit 2026-07-30: overlapping answer submits lost each other's
session advance.

``get_session`` hands out a deep copy and ``update_session`` replaces the whole
object with no version check, while ``process_answer`` mutates that copy across
several awaits (parse → evaluate → translate → usage) before writing it back.
Two submits that overlap therefore both read the same snapshot and the last write
wins: the question returned to the first client is never recorded in
``asked_question_ids``, the stored ``current_question_id`` disagrees with what
that client is showing, and one of the two recorded freemium questions has no
served question behind it. iOS reaches this without a double-tap — its retry
wrapper re-sends on ``URLError.timedOut`` while the original request is still in
flight.

The fix is a per-session ``asyncio.Lock`` held by the submit routes across the
whole read→process→write. This test is deterministic: it parks the first submit
inside the evaluator on an ``asyncio.Event`` and yields control cooperatively —
no wall-clock sleeps, so it cannot flake.
"""

import asyncio
import os
from unittest.mock import AsyncMock, MagicMock

import pytest

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from app.api.deps import SubmitInputRequest  # noqa: E402
from app.api.routes.quiz import submit_input  # noqa: E402
from app.input.parser import InputParser  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.session.manager import SessionManager  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.models.phase import SessionPhase  # noqa: E402

pytestmark = pytest.mark.asyncio


class _Url:
    path = "/api/v1/sessions/x/input"


class _Req:
    url = _Url()
    headers: dict = {}


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


def _question(qid: str) -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


async def _yield_control() -> None:
    """Let every other ready task run — a cooperative yield, not a delay."""
    for _ in range(20):
        await asyncio.sleep(0)


async def test_overlapping_submits_are_serialized_per_session():
    """The second submit must see the first one's committed session.

    Pins the three symptoms of the lost update at once: every question handed to
    a client is recorded in the stored history, the stored current question is
    the last one served, and the freemium counter is debited exactly once per
    served question — never for a question the server then forgot.
    """
    manager = SessionManager()
    session = manager.create_session(user_id="u_race")
    session.transition(to=SessionPhase.ASKING, caller="test")
    session.current_question_id = "q1"
    session.asked_question_ids = ["q1"]
    manager.update_session(session)

    evaluated: list[str] = []
    first_entered = asyncio.Event()
    release_first = asyncio.Event()

    async def _evaluate(*, user_answer, question, question_text):
        evaluated.append(question.id)
        if len(evaluated) == 1:
            first_entered.set()
            await release_first.wait()
        return "correct", 1.0

    retriever = MagicMock()
    retriever.get = MagicMock(side_effect=_question)
    retriever.get_next_question = MagicMock(
        side_effect=[_question("q2"), _question("q3")]
    )

    usage_tracker = MagicMock()
    usage_tracker.check_limit = AsyncMock(return_value=(True, 10, None))
    usage_tracker.record_question = AsyncMock()

    flow = QuizFlowService(
        session_manager=manager,
        input_parser=InputParser(),
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=usage_tracker,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(side_effect=_evaluate)

    def _submit():
        return asyncio.create_task(
            submit_input(
                request=_Req(),
                session_id=session.session_id,
                body=SubmitInputRequest(input="Paris"),
                session_manager=manager,
                quiz_flow=flow,
            )
        )

    first = _submit()
    await first_entered.wait()  # first submit is inside the flow, holding the lock

    second = _submit()
    await _yield_control()
    # Without the lock the second submit would already have read the same stale
    # snapshot and evaluated q1 a second time.
    assert evaluated == ["q1"]

    release_first.set()
    response_first = await first
    response_second = await second

    served = [
        response_first.current_question.id,
        response_second.current_question.id,
    ]
    stored = manager.get_session(session.session_id)

    assert served == ["q2", "q3"]
    assert evaluated == ["q1", "q2"]  # the second submit saw the first's write
    assert stored.asked_question_ids == ["q1", "q2", "q3"]
    assert stored.current_question_id == "q3"
    assert usage_tracker.record_question.await_count == len(served)


async def test_session_lock_is_dropped_with_the_session():
    """The lock table must not outlive its sessions — one lock per live session,
    released on delete and on expiry cleanup."""
    manager = SessionManager()
    session = manager.create_session()

    manager.session_lock(session.session_id)
    assert session.session_id in manager._session_locks

    manager.delete_session(session.session_id)
    assert manager._session_locks == {}


async def test_same_session_returns_the_same_lock_object():
    """Two concurrent requests must contend on ONE mutex — a fresh lock per call
    would serialize nothing."""
    manager = SessionManager()
    session = manager.create_session()

    assert manager.session_lock(session.session_id) is manager.session_lock(
        session.session_id
    )
