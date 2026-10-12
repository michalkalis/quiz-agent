"""#200: starting a pack that has nothing left to play is a typed 409, not a 500.

With #200 a pack plays the player's "questions per quiz" count, so a 30-question
pack is heard across several shorter sets, each excluding what the client has
already heard. The start after the last set finds nothing: before #200 that
fell into the shared-corpus diagnostics and answered a 500 "No questions match
the criteria", which the app shows as a server fault and offers to retry —
forever. It must be a client-recognisable ``pack_exhausted`` 409 (nothing to
retry), and the session must stay startable rather than half-started.

A pack still being generated keeps #182's behaviour (park and poll), and a
normal session keeps its corpus diagnostics — both pinned as contrast cases.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException

from app.api.deps import StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.auth.identity import AuthSubject
from app.session.manager import SessionManager
from quiz_shared.models.phase import SessionPhase

pytestmark = pytest.mark.asyncio

PACK_ID = "e5b8c1a2-0000-4000-8000-000000000abc"


class _Url:
    path = "/api/v1/sessions/x/start"


class _Req:
    url = _Url()
    headers: dict = {}


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


def _retriever(*, generating: bool) -> MagicMock:
    retriever = MagicMock()
    retriever.get_next_question = AsyncMock(return_value=None)
    retriever.pack_is_generating = AsyncMock(return_value=generating)
    retriever.count = AsyncMock(return_value=500)  # the shared corpus is full
    return retriever


async def _start(manager, session_id, retriever, heard: list[str]):
    return await start_quiz(
        request=_Req(),
        session_id=session_id,
        body=StartQuizRequest(excluded_question_ids=heard),
        session_manager=manager,
        question_retriever=retriever,
        usage_tracker=None,
        translation_service=None,
        tts_service=MagicMock(),
        audio=False,
        subject=AuthSubject(subject_id="u1", is_legacy=False, authenticated=True),
    )


def _session(manager: SessionManager, pack_id: str | None):
    session = manager.create_session(user_id="u1", max_questions=10)
    session.pack_id = pack_id
    manager.update_session(session)
    return session


async def test_a_fully_heard_closed_pack_answers_a_coded_409():
    manager = SessionManager()
    session = _session(manager, PACK_ID)

    with pytest.raises(HTTPException) as exc:
        await _start(manager, session.session_id, _retriever(generating=False), ["q1"])

    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "pack_exhausted"
    # Nothing was started: the stored session can still be started or dropped.
    assert manager.get_session(session.session_id).phase == SessionPhase.IDLE


async def test_a_still_generating_pack_parks_instead_of_failing():
    manager = SessionManager()
    session = _session(manager, PACK_ID)

    response = await _start(
        manager, session.session_id, _retriever(generating=True), ["q1"]
    )

    assert response.awaiting_question is True


async def test_a_normal_session_keeps_its_corpus_diagnostics():
    manager = SessionManager()
    session = _session(manager, None)

    with pytest.raises(HTTPException) as exc:
        await _start(manager, session.session_id, _retriever(generating=False), [])

    assert exc.value.status_code == 500
    assert "No questions match" in exc.value.detail
