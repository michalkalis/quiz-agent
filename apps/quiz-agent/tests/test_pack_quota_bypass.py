"""Custom-pack sessions bypass the free monthly quota (#95, founder decision 2).

Intent: a custom pack is paid, curated content, so playing it must neither be
blocked by the 30/month free limit nor count against it. The guard lives in the
question-serving path — ``start_quiz`` for the first question (and
``flow.process_answer`` for the rest, same condition). These tests pin that a
pack session never touches the usage tracker while a normal session still does,
so a refactor that drops the ``not session.pack_id`` clause (re-charging paid
packs) or the whole guard (giving away free questions) fails loudly.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from quiz_shared.models.question import Question

from app.api.deps import StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.session.manager import SessionManager

pytestmark = pytest.mark.asyncio


class _Url:
    path = "/api/v1/sessions/x/start"


class _Req:
    url = _Url()
    headers: dict = {}


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


def _make_question() -> Question:
    # review_status mirrors reality: delivered pack questions are pending_review,
    # never "approved" — the retriever pack-branch is what makes them servable.
    return Question(
        id="q-pack-1",
        question="What is it?",
        type="text",
        correct_answer="answer",
        topic="Custom",
        category="general",
        difficulty="medium",
        review_status="pending_review",
    )


def _tracker() -> MagicMock:
    tracker = MagicMock()
    tracker.check_limit = AsyncMock(return_value=(True, 29, "2026-08-01T00:00:00Z"))
    tracker.record_question = AsyncMock()
    tracker.get_usage = AsyncMock(
        return_value={
            "questions_used": 1,
            "questions_limit": 30,
            "resets_at": "2026-08-01T00:00:00Z",
        }
    )
    return tracker


async def _start(manager: SessionManager, session_id: str, tracker: MagicMock):
    retriever = MagicMock()
    retriever.get_next_question.return_value = _make_question()
    return await start_quiz(
        request=_Req(),
        session_id=session_id,
        body=StartQuizRequest(),
        session_manager=manager,
        question_retriever=retriever,
        usage_tracker=tracker,
        translation_service=None,
        tts_service=MagicMock(),
        audio=False,
    )


async def test_pack_session_does_not_touch_quota():
    manager = SessionManager()
    session = manager.create_session(user_id="u1")
    session.pack_id = "e5b8c1a2-0000-4000-8000-000000000abc"
    manager.update_session(session)
    tracker = _tracker()

    await _start(manager, session.session_id, tracker)

    tracker.check_limit.assert_not_awaited()  # never gated by the free limit
    tracker.record_question.assert_not_awaited()  # never counted against it


async def test_normal_session_still_charges_quota():
    # The contrast case: without a pack_id the same path MUST gate + record, so
    # this test fails if the guard is widened to skip the quota for everyone.
    manager = SessionManager()
    session = manager.create_session(user_id="u1")
    manager.update_session(session)
    tracker = _tracker()

    await _start(manager, session.session_id, tracker)

    tracker.check_limit.assert_awaited_once()
    tracker.record_question.assert_awaited_once()
