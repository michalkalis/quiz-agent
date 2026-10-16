"""Two quiz-agent machines on one Postgres (#207.20, resilience design step 3).

Why: with the volume gone, prod runs two machines and Fly's proxy may send
consecutive requests of one quiz to different machines. The single-machine
guarantees must hold across machines:

- a quiz started on one machine continues on the other;
- an iOS retry of a submit landing on the *other* machine while the first is
  still in flight must wait and then read the first one's result — never
  grade the same snapshot twice, lose a question advance or debit the
  freemium quota twice;
- the audio route's best-effort write of the question text must never undo a
  submit's advance;
- a machine that dies mid-request must not block the session forever.

Each "machine" is its own ``SessionManager`` (own in-process locks) sharing
only the database, exactly like two Fly machines.
"""

from __future__ import annotations

import asyncio
import os
from unittest.mock import AsyncMock, MagicMock

import pytest

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from app.api.deps import SubmitInputRequest  # noqa: E402
from app.api.routes.quiz import submit_input  # noqa: E402
from app.api.routes.tts import _remember_question_text  # noqa: E402
from app.auth.identity import AuthSubject  # noqa: E402
from app.coordination.leases import LeaseStore  # noqa: E402
from app.input.parser import InputParser  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.session.manager import SessionConflict, SessionManager  # noqa: E402
from app.session.store import PostgresSessionStore  # noqa: E402
from app.usage.caps import UsageCaps  # noqa: E402
from quiz_shared.models.phase import SessionPhase  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

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


class _WatchedLeases(LeaseStore):
    """A machine's lease store that signals when it had to wait."""

    def __init__(self, sm) -> None:
        super().__init__(sm)
        self.refused = asyncio.Event()

    async def try_acquire(self, name, holder, ttl_s):
        ok = await super().try_acquire(name, holder, ttl_s)
        if not ok:
            self.refused.set()
        return ok


def _machine(sm) -> SessionManager:
    return SessionManager(store=PostgresSessionStore(sm), leases=_WatchedLeases(sm))


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


async def _asking_session(manager: SessionManager, user: str):
    session = await manager.create_session(user_id=user)
    session.transition(to=SessionPhase.ASKING, caller="test")
    session.current_question_id = "q1"
    session.asked_question_ids = ["q1"]
    await manager.update_session(session)
    return session


async def test_a_quiz_started_on_one_machine_continues_on_the_other(db_sessionmaker):
    a, b = _machine(db_sessionmaker), _machine(db_sessionmaker)
    session = await _asking_session(a, "u_move")

    on_b = await b.get_session(session.session_id)
    assert on_b is not None and on_b.current_question_id == "q1"
    on_b.current_question_id = "q2"
    on_b.asked_question_ids.append("q2")
    assert await b.update_session(on_b)

    back_on_a = await a.get_session(session.session_id)
    assert back_on_a.asked_question_ids == ["q1", "q2"]


async def test_duplicate_submit_on_the_other_machine_waits_for_the_first(
    db_sessionmaker,
):
    """The cross-machine version of test_session_submit_serialization: the
    retry reaches machine B while machine A is still grading. B must not read
    the pre-grade snapshot (it would grade q1 again, serve a question the
    stored session never records and debit the quota for it)."""
    a, b = _machine(db_sessionmaker), _machine(db_sessionmaker)
    session = await _asking_session(a, "u_race")

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
    retriever.get = AsyncMock(side_effect=_question)
    retriever.get_next_question = AsyncMock(
        side_effect=[_question("q2"), _question("q3")]
    )
    usage_tracker = MagicMock()
    usage_tracker.check_limit = AsyncMock(return_value=(True, 10, None))
    usage_tracker.record_question = AsyncMock()

    def _flow(manager):
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
        return flow

    def _submit(manager):
        return asyncio.create_task(
            submit_input(
                request=_Req(),
                session_id=session.session_id,
                body=SubmitInputRequest(input="Paris"),
                session_manager=manager,
                quiz_flow=_flow(manager),
                subject=AuthSubject(
                    subject_id="u_race", is_legacy=False, authenticated=True
                ),
                usage_caps=UsageCaps(None),
            )
        )

    first = _submit(a)
    await first_entered.wait()  # A is inside the flow, holding the lease
    second = _submit(b)
    await asyncio.wait_for(b._leases.refused.wait(), timeout=10)
    # B is blocked on the lease, not grading the stale snapshot.
    assert evaluated == ["q1"]

    release_first.set()
    response_first = await first
    response_second = await asyncio.wait_for(second, timeout=10)

    served = [response_first.current_question.id, response_second.current_question.id]
    stored = await a.get_session(session.session_id)
    assert served == ["q2", "q3"]
    assert evaluated == ["q1", "q2"]  # B graded against A's committed advance
    assert stored.asked_question_ids == ["q1", "q2", "q3"]
    assert stored.current_question_id == "q3"
    assert usage_tracker.record_question.await_count == len(served)


async def test_audio_text_write_never_undoes_a_submit_on_the_other_machine(
    db_sessionmaker,
):
    """The audio route read the session, awaited a translation, and used to
    write that old copy back — reverting an advance made meanwhile. Now it
    skips while a submit holds the session and re-reads before writing."""
    a, b = _machine(db_sessionmaker), _machine(db_sessionmaker)
    session = await _asking_session(a, "u_tts")
    audio_copy = await b.get_session(session.session_id)  # B: read before await

    async with a.session_lock(session.session_id):  # A: submit in flight
        await _remember_question_text(b, audio_copy, "Otázka q1?", {"q": 1})
        advanced = await a.get_session(session.session_id)
        advanced.current_question_id = "q2"
        advanced.asked_question_ids.append("q2")
        await a.update_session(advanced)

    # After the submit: the stale copy points at q1, so nothing is written.
    await _remember_question_text(b, audio_copy, "Otázka q1?", {"q": 1})
    stored = await a.get_session(session.session_id)
    assert stored.current_question_id == "q2"
    assert stored.asked_question_ids == ["q1", "q2"]
    assert stored.current_question_text is None

    # And a raw stale write is refused outright, not silently applied.
    audio_copy.current_question_text = "stale"
    with pytest.raises(SessionConflict):
        await b.update_session(audio_copy)


async def test_audio_text_is_kept_when_the_session_is_idle(db_sessionmaker):
    a, b = _machine(db_sessionmaker), _machine(db_sessionmaker)
    session = await _asking_session(a, "u_tts_ok")
    copy = await b.get_session(session.session_id)
    await _remember_question_text(b, copy, "Otázka q1?", {"q": 1})
    stored = await a.get_session(session.session_id)
    assert stored.current_question_text == "Otázka q1?"


async def test_a_dead_holder_frees_the_lease_by_expiry(db_sessionmaker):
    """A machine killed mid-submit never releases; the other must take over
    once the lease expires instead of waiting forever."""
    leases = LeaseStore(db_sessionmaker)
    assert await leases.try_acquire("session:x", "machine-a", 0.3)
    assert not await leases.try_acquire("session:x", "machine-b", 0.3)
    await asyncio.sleep(0.5)
    assert await leases.try_acquire("session:x", "machine-b", 0.3)
    # The renewing holder keeps it (leader lease relies on this).
    assert await leases.try_acquire("session:x", "machine-b", 0.3)


async def test_erasure_mid_request_cannot_write_the_id_back(db_sessionmaker):
    """GDPR: an in-flight request holding an old copy must not re-persist the
    erased account's id after ``forget_user``."""
    a, b = _machine(db_sessionmaker), _machine(db_sessionmaker)
    session = await _asking_session(a, "u_erase")
    in_flight = await a.get_session(session.session_id)

    sessions, _ = await b.forget_user("u_erase")
    assert sessions == 1
    in_flight.score = 1.0
    assert await a.update_session(in_flight) is False  # gone, not written

    async with db_sessionmaker() as db:
        from sqlalchemy import text

        raw = await db.scalar(
            text("SELECT data_json FROM quiz_sessions WHERE session_id = :s"),
            {"s": session.session_id},
        )
    assert "u_erase" not in raw
