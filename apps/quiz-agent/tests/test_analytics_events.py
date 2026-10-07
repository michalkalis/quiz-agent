"""#51: first-party product analytics — what may be stored, and that it is.

Why these tests exist:
- The allowlist IS the privacy guarantee: an event or property key not in
  ``app.analytics.taxonomy`` must never reach the table (no transcript, no
  free text can ride in on an ad-hoc key), and long strings are cut.
- Analytics must never cost the player anything: a server emit with no DB, an
  unknown name or a failing write is silent, never an exception.
- The founder's metrics come from these rows (completion rate, wrong-answer
  rate, quota pressure), so the flow must emit them at the real transitions.
- GDPR erase must take the subject's events with it.
"""

from __future__ import annotations

import asyncio
import os
from datetime import datetime, timedelta, timezone
from typing import Any
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from slowapi import _rate_limit_exceeded_handler  # noqa: E402
from slowapi.errors import RateLimitExceeded  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.analytics.recorder import (  # noqa: E402
    AnalyticsRecorder,
    ClientEvent,
    app_version_var,
    drain_pending,
)
from app.analytics.taxonomy import MAX_STRING_LEN, clean_properties  # noqa: E402
from app.api import deps  # noqa: E402
from app.api.routes import analytics as analytics_routes  # noqa: E402
from app.auth.identity import AuthSubject  # noqa: E402
from app.db.models import AnalyticsEvent  # noqa: E402
from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.rate_limit import limiter  # noqa: E402
from quiz_shared.models.participant import Participant  # noqa: E402
from quiz_shared.models.phase import SessionPhase  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.models.session import QuizSession  # noqa: E402

pytestmark = pytest.mark.asyncio


class _SpyRecorder(AnalyticsRecorder):
    """Captures server emits (after the same allowlist cleaning) in memory."""

    def __init__(self):
        super().__init__(None)
        self.events: list[tuple[str, dict[str, Any]]] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        from app.analytics.taxonomy import SERVER_EVENTS

        assert name in SERVER_EVENTS, f"{name} is not in the taxonomy"
        self.events.append(
            (name, clean_properties(SERVER_EVENTS[name], properties or {}))
        )

    def named(self, name):
        return [props for n, props in self.events if n == name]


async def _rows(sessionmaker) -> list[AnalyticsEvent]:
    async with sessionmaker() as s:
        return list((await s.execute(select(AnalyticsEvent))).scalars())


# ── Allowlist (no DB) ────────────────────────────────────────────────────────


async def test_only_allowlisted_scalar_properties_survive():
    cleaned = clean_properties(
        frozenset({"source", "count", "flag"}),
        {
            "source": "x" * 500,
            "count": 3,
            "flag": True,
            "transcript": "my home address is…",  # not allowlisted
            "source_list": ["a"],
        },
    )
    assert cleaned == {"source": "x" * MAX_STRING_LEN, "count": 3, "flag": True}


async def test_server_emit_never_raises_without_db_or_for_unknown_names():
    recorder = AnalyticsRecorder(None)
    recorder.emit("quiz_started", subject_id="u", properties={"language": "sk"})
    recorder.emit("not_an_event")  # logged, dropped
    await drain_pending()


async def test_a_failing_write_is_swallowed():
    def _broken():
        raise RuntimeError("db down")

    recorder = AnalyticsRecorder(_broken)
    recorder.emit("quiz_started", subject_id="u")
    await drain_pending()  # would raise if the failure escaped the task


# ── Persistence (DB) ─────────────────────────────────────────────────────────


async def test_server_emit_persists_cleaned_row_with_app_version(db_sessionmaker):
    recorder = AnalyticsRecorder(db_sessionmaker)
    token = app_version_var.set("1.4 (77)")
    try:
        recorder.emit(
            "quota_hit",
            subject_id="anon-1",
            session_id="s1",
            properties={"stage": "start", "questions_used": 30, "email": "x@y"},
        )
    finally:
        app_version_var.reset(token)
    await drain_pending()

    (row,) = await _rows(db_sessionmaker)
    assert (row.name, row.subject_id, row.session_id, row.source) == (
        "quota_hit",
        "anon-1",
        "s1",
        "server",
    )
    assert row.app_version == "1.4 (77)"
    assert row.properties == {"stage": "start", "questions_used": 30}


async def test_client_batch_drops_unknown_events_and_clamps_future_clock(
    db_sessionmaker,
):
    recorder = AnalyticsRecorder(db_sessionmaker)
    future = datetime.now(timezone.utc) + timedelta(days=3)
    accepted, dropped = await recorder.record_client_batch(
        [
            ClientEvent("paywall_viewed", future, None, {"source": "quota"}),
            ClientEvent("quiz_started", None, "s1", {}),  # server-only name
            ClientEvent("made_up", None, None, {}),
        ],
        subject_id="anon-2",
        app_version="1.4",
    )
    assert (accepted, dropped) == (1, 2)
    (row,) = await _rows(db_sessionmaker)
    assert row.name == "paywall_viewed" and row.source == "ios"
    assert row.occurred_at <= datetime.now(timezone.utc)


async def test_ingest_route_takes_subject_from_bearer_not_body(db_sessionmaker):
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(analytics_routes.router, prefix="/api/v1")
    app.state.analytics = AnalyticsRecorder(db_sessionmaker)
    app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
        subject_id="anon-bearer", is_legacy=False, authenticated=True
    )
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        ok = await client.post(
            "/api/v1/analytics/events",
            headers={"X-App-Version": "1.5"},
            json={
                "subject_id": "someone-else",
                "events": [
                    {
                        "name": "voice_command",
                        "properties": {"command": "skip", "phase": "asking"},
                    }
                ],
            },
        )
        too_big = await client.post(
            "/api/v1/analytics/events",
            json={"events": [{"name": "app_opened"}] * 51},
        )

    assert ok.status_code == 200 and ok.json() == {"accepted": 1, "dropped": 0}
    assert too_big.status_code == 422
    (row,) = await _rows(db_sessionmaker)
    assert row.subject_id == "anon-bearer"
    assert row.app_version == "1.5"


async def test_account_erase_deletes_the_subjects_events(db_sessionmaker):
    import uuid

    from app.auth.account_service import erase_account
    from app.db.models import User

    user_id = uuid.uuid4()
    async with db_sessionmaker() as s:
        s.add(User(id=user_id, apple_sub="apple-sub-51"))
        await s.commit()
    recorder = AnalyticsRecorder(db_sessionmaker)
    await recorder.record_client_batch(
        [ClientEvent("app_opened", None, None, {})],
        subject_id=str(user_id),
        app_version=None,
    )
    await recorder.record_client_batch(
        [ClientEvent("app_opened", None, None, {})],
        subject_id="someone-else",
        app_version=None,
    )
    async with db_sessionmaker() as s:
        user = await s.get(User, user_id)
        await erase_account(s, user)
        await s.commit()

    assert [r.subject_id for r in await _rows(db_sessionmaker)] == ["someone-else"]


# ── Flow emits at the real transitions (no DB) ───────────────────────────────


def _mcq(qid: str) -> Question:
    # MCQ so the real evaluator grades deterministically (no LLM call).
    return Question(
        id=qid,
        question="Which planet is the farthest from the Sun?",
        type="text_multichoice",
        possible_answers={"a": "Mars", "b": "Venus", "c": "Neptune", "d": "Saturn"},
        correct_answer="c",
        topic="Space",
        category="science",
        difficulty="easy",
    )


class _Manager:
    def update_session(self, session):
        return True


def _flow(spy, *, allowed=True, next_question=None) -> QuizFlowService:
    async def _parse(user_input, current_question, phase):
        return [{"intent_type": "answer", "extracted_data": {"answer": user_input}}]

    parser = MagicMock()
    parser.parse = AsyncMock(side_effect=_parse)
    retriever = MagicMock()
    retriever.get = AsyncMock(side_effect=_mcq)
    retriever.get_next_question = AsyncMock(return_value=next_question)
    retriever.pack_is_generating = AsyncMock(return_value=False)
    usage = MagicMock()
    usage.check_limit = AsyncMock(return_value=(allowed, 0, None))
    usage.get_usage = AsyncMock(
        return_value={"questions_used": 30, "questions_limit": 30, "resets_at": "x"}
    )
    usage.record_question = AsyncMock()
    return QuizFlowService(
        session_manager=_Manager(),
        input_parser=parser,
        question_retriever=retriever,
        answer_evaluator=AnswerEvaluator(),
        tts_service=None,
        usage_tracker=usage,
        translation_service=None,
        analytics=spy,
    )


def _session(max_questions: int) -> QuizSession:
    return QuizSession(
        session_id="s51",
        user_id="anon-51",
        phase=SessionPhase.ASKING,
        current_question_id="q1",
        asked_question_ids=["q1"],
        max_questions=max_questions,
        participants=[Participant(participant_id="p1", display_name="Driver")],
    )


async def test_last_answer_emits_graded_answer_and_completion():
    """Completion rate + wrong-answer rate both come from this one path."""
    spy = _SpyRecorder()
    await _flow(spy).process_answer(_session(1), "Neptune", route="voice")

    (answer,) = spy.named("answer_evaluated")
    assert answer["result"] == "correct"
    assert answer["route"] == "voice"
    assert answer["question_type"] == "text_multichoice"
    assert answer["category"] == "science"
    (done,) = spy.named("quiz_completed")
    assert done == {
        "reason": "max_questions",
        "questions_asked": 1,
        "score": 1.0,
        "is_pack": False,
    }


async def test_running_out_of_free_questions_mid_quiz_emits_quota_hit():
    """Quota pressure is the upgrade-funnel signal (#93)."""
    spy = _SpyRecorder()
    await _flow(spy, allowed=False).process_answer(_session(10), "Mars", route="text")

    assert spy.named("quota_hit") == [
        {"stage": "mid_quiz", "questions_used": 30, "questions_limit": 30}
    ]
    assert spy.named("quiz_completed")[0]["reason"] == "usage_limit"
    assert spy.named("answer_evaluated")[0]["result"] == "incorrect"


async def test_a_mid_quiz_answer_does_not_claim_completion():
    spy = _SpyRecorder()
    flow = _flow(spy, next_question=_mcq("q2"))
    flow._advance_to_question = AsyncMock(side_effect=lambda s, q, r, a: r)
    await flow.process_answer(_session(10), "Neptune", route="text")

    assert len(spy.named("answer_evaluated")) == 1
    assert spy.named("quiz_completed") == []
    await asyncio.sleep(0)
