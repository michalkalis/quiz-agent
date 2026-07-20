"""Response-level test for the paywall trigger (backend arch review
2026-07-18, testability finding "no response-level test for the paywall
trigger").

WHY this matters — not just what it does: the 429 ``quota_limit_reached``
payload and the ``usage_limit_error`` branch in ``quiz.py::start_quiz`` are
the exact contract iOS keys the paywall renders on (``error``,
``questions_used``, ``questions_limit``, ``resets_at``,
``upgrade_available``) — a renamed or dropped field here breaks the paywall
silently, since nothing else in the suite asserts on the SHAPE of this
response. The closest existing coverage (``test_pack_quota_bypass.py``) stubs
``check_limit`` to always allow, so it never exercises the deny branch at
all. This test drives a REAL DB-backed ``UsageTracker`` to genuine
exhaustion — both the free monthly allotment (consumed through the tracker's
own ``record_question`` path, the same one production traffic uses) AND pack
credits (zero by construction — no ``credit_ledger`` rows are seeded) — and
asserts on the actual route response, plus that the deny never reaches
``record_question`` (no phantom usage charged on a denied request).
"""

from __future__ import annotations

from datetime import datetime
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException

from quiz_shared.models.question import Question

from app.api.deps import StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.session.manager import SessionManager
from app.usage.tracker import UsageTracker

pytestmark = pytest.mark.asyncio

SUBJECT = "paywall-test-subject"


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
    return Question(
        id="q-paywall-1",
        question="What is it?",
        type="text",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
        review_status="approved",
    )


async def test_start_quiz_denies_with_paywall_contract_when_quota_and_credits_exhausted(
    db_sessionmaker,
):
    """A subject with no subscription, no free allotment left, and no pack
    credits gets a 429 whose body iOS's paywall parses verbatim — and
    ``record_question`` is never awaited on the deny path."""
    tracker = UsageTracker(db_sessionmaker, monthly_limit=2)

    # Exhaust the free allotment the same way production traffic does.
    await tracker.record_question(SUBJECT)
    await tracker.record_question(SUBJECT)

    # Sanity check the fixture actually reached "exhausted" before hitting
    # the route — no credit_ledger rows exist for this subject either, so
    # this is genuinely quota AND credits exhausted, not quota alone.
    allowed, remaining, _ = await tracker.check_limit(SUBJECT)
    assert allowed is False
    assert remaining == 0

    spy_record = AsyncMock(wraps=tracker.record_question)
    tracker.record_question = spy_record

    manager = SessionManager()
    session = manager.create_session(user_id=SUBJECT)
    manager.update_session(session)

    retriever = MagicMock()
    retriever.get_next_question.return_value = _make_question()

    with pytest.raises(HTTPException) as exc_info:
        await start_quiz(
            request=_Req(),
            session_id=session.session_id,
            body=StartQuizRequest(),
            session_manager=manager,
            question_retriever=retriever,
            usage_tracker=tracker,
            translation_service=None,
            tts_service=MagicMock(),
            audio=False,
        )

    exc = exc_info.value
    assert exc.status_code == 429
    # Exact contract keys/values iOS's paywall renders on (quiz.py:70-76).
    assert exc.detail["error"] == "quota_limit_reached"
    assert exc.detail["questions_used"] == 2
    assert exc.detail["questions_limit"] == 2
    assert exc.detail["upgrade_available"] is True
    # A real ISO-8601 timestamp, not just a present key.
    datetime.fromisoformat(exc.detail["resets_at"])

    spy_record.assert_not_awaited()
