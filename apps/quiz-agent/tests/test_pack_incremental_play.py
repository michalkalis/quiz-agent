"""#182 — playing a custom pack while it is still being generated.

Why these scenarios:
- A pack session whose next question is not persisted yet must NOT end the
  quiz ("No more questions") — that was the only outcome before #182 and it
  would cut a paid 30-pack short at whatever batch the player caught up with.
- The parked session must resume through `resume_after_wait` exactly like a
  question served after an answer (same advance path), or finish cleanly once
  the pack is closed with nothing left.
- Non-pack sessions and pack sessions on a closed pack keep today's behaviour.
- The endpoint rejects a session that is not parked and replays the active
  question instead of skipping it when a client retries.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest
from app.api.routes.quiz import next_question
from app.auth.identity import AuthSubject
from app.quiz.flow import QuizFlowService
from app.session.manager import SessionManager
from fastapi import HTTPException
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question

pytestmark = pytest.mark.asyncio

PACK_ID = "e5b8c1a2-0000-4000-8000-000000000abc"


class _Url:
    path = "/api/v1/sessions/x/next-question"


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
        correct_answer="answer",
        topic="Custom",
        category="general",
        difficulty="medium",
        review_status="pending_review",
    )


def _retriever(next_questions: list, generating: bool) -> MagicMock:
    retriever = MagicMock()
    retriever.get_next_question = AsyncMock(side_effect=list(next_questions))
    retriever.pack_is_generating = AsyncMock(return_value=generating)
    retriever.get_translations = AsyncMock(return_value={})
    return retriever


def _flow(manager: SessionManager, retriever: MagicMock) -> QuizFlowService:
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "answer"}}]
    )
    evaluator = MagicMock()
    evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    return QuizFlowService(
        session_manager=manager,
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=evaluator,
        tts_service=None,
        usage_tracker=None,
        translation_service=None,
    )


def _pack_session(manager: SessionManager, *, pack_id: str | None = PACK_ID):
    session = manager.create_session(user_id="u1", max_questions=30)
    session.pack_id = pack_id
    session.current_question_id = "q1"
    session.asked_question_ids = ["q1"]
    session.transition(to=SessionPhase.ASKING, caller="test")
    manager.update_session(session)
    return session


async def test_answer_on_a_still_generating_pack_parks_instead_of_finishing():
    manager = SessionManager()
    session = _pack_session(manager)
    retriever = _retriever([None], generating=True)
    retriever.get = AsyncMock(return_value=_question("q1"))
    flow = _flow(manager, retriever)

    result = await flow.process_answer(session=session, answer_text="answer")

    assert result.evaluation is not None, "the answer itself was still graded"
    assert result.awaiting_question is True
    assert result.quiz_finished is False
    assert result.next_question_dict is None
    stored = manager.get_session(session.session_id)
    assert stored.phase == SessionPhase.ASKING
    assert stored.current_question_id is None


async def test_answer_on_a_closed_pack_still_finishes_when_exhausted():
    manager = SessionManager()
    session = _pack_session(manager)
    retriever = _retriever([None], generating=False)
    retriever.get = AsyncMock(return_value=_question("q1"))
    flow = _flow(manager, retriever)

    result = await flow.process_answer(session=session, answer_text="answer")

    assert result.awaiting_question is False
    assert result.quiz_finished is True
    assert manager.get_session(session.session_id).phase == SessionPhase.FINISHED


async def test_non_pack_session_never_probes_pack_state():
    manager = SessionManager()
    session = _pack_session(manager, pack_id=None)
    retriever = _retriever([None], generating=True)
    retriever.get = AsyncMock(return_value=_question("q1"))
    flow = _flow(manager, retriever)

    result = await flow.process_answer(session=session, answer_text="answer")

    assert result.quiz_finished is True
    retriever.pack_is_generating.assert_not_awaited()


async def test_resume_serves_the_question_once_it_lands():
    manager = SessionManager()
    session = _pack_session(manager)
    session.current_question_id = None
    manager.update_session(session)
    retriever = _retriever([None, _question("q2")], generating=True)
    flow = _flow(manager, retriever)

    result = await flow.resume_after_wait(session, wait_seconds=5.0, poll_interval=0.01)

    assert result.awaiting_question is False
    assert result.next_question_dict["id"] == "q2"
    stored = manager.get_session(session.session_id)
    assert stored.current_question_id == "q2"
    assert stored.asked_question_ids == ["q1", "q2"]


async def test_resume_reports_waiting_again_when_the_wait_budget_runs_out():
    manager = SessionManager()
    session = _pack_session(manager)
    session.current_question_id = None
    manager.update_session(session)
    retriever = _retriever([None, None, None], generating=True)
    flow = _flow(manager, retriever)

    result = await flow.resume_after_wait(
        session, wait_seconds=0.02, poll_interval=0.01
    )

    assert result.awaiting_question is True
    assert manager.get_session(session.session_id).phase == SessionPhase.ASKING


async def test_resume_finishes_once_the_pack_closed_with_nothing_left():
    manager = SessionManager()
    session = _pack_session(manager)
    session.current_question_id = None
    manager.update_session(session)
    retriever = _retriever([None], generating=False)
    flow = _flow(manager, retriever)

    result = await flow.resume_after_wait(session, wait_seconds=0.0)

    assert result.quiz_finished is True
    assert manager.get_session(session.session_id).phase == SessionPhase.FINISHED


async def _call_endpoint(manager, session_id, flow, retriever):
    return await next_question(
        request=_Req(),
        session_id=session_id,
        session_manager=manager,
        quiz_flow=flow,
        question_retriever=retriever,
        translation_service=None,
        audio=False,
        subject=AuthSubject(subject_id="u1", is_legacy=False, authenticated=True),
    )


async def test_endpoint_rejects_a_session_that_is_not_parked():
    manager = SessionManager()
    session = manager.create_session(user_id="u1")  # still idle
    retriever = _retriever([], generating=True)

    with pytest.raises(HTTPException) as exc:
        await _call_endpoint(
            manager, session.session_id, _flow(manager, retriever), retriever
        )

    assert exc.value.status_code == 400


async def test_endpoint_replays_the_active_question_instead_of_skipping_it():
    manager = SessionManager()
    session = _pack_session(manager)  # q1 active
    retriever = _retriever([], generating=True)
    retriever.get = AsyncMock(return_value=_question("q1"))
    flow = _flow(manager, retriever)

    response = await _call_endpoint(manager, session.session_id, flow, retriever)

    assert response.current_question.id == "q1"
    assert response.awaiting_question is False
    retriever.get_next_question.assert_not_awaited()


async def test_endpoint_returns_awaiting_flag_while_pack_generates(monkeypatch):
    from app.api.routes import quiz as quiz_routes

    monkeypatch.setattr(quiz_routes, "NEXT_QUESTION_WAIT_SECONDS", 0.0)
    manager = SessionManager()
    session = _pack_session(manager)
    session.current_question_id = None
    manager.update_session(session)
    retriever = _retriever([None], generating=True)
    flow = _flow(manager, retriever)

    response = await _call_endpoint(manager, session.session_id, flow, retriever)

    assert response.awaiting_question is True
    assert response.current_question is None
    assert response.session.phase == "asking"
