"""#236 — Rodinná sekcia „S deťmi“, increment S2: what a round with kids may not do.

A round with kids is a session whose ``age_band`` is set (server state, never
sent back by an old build). It plays only questions written for that band,
whose category is a ``family-*`` key. Each guard below exists for one reason:

* **No share link.** The snapshot re-reads the ids through the ordinary
  serving filters, which never return a band question: the link would carry
  no questions and the friend would get some other quiz.
* **No game together.** v1 is one parent answering with the kids at one
  phone; a room with a band is a later step.
* **Not in the parent's stats.** Stats, streak, speed and recaps describe the
  parent as a player; a round played with a child (and the child's guesses,
  including a verdict corrected after an edited transcript) must not change
  them.
* **Quota (founder 2026-11-18).** The round counts toward the free monthly
  questions like an ordinary quiz, but a started round always finishes: no
  cut-off and no purchase prompt mid-round, and nothing goes below zero.

Every guard has its ordinary-session contrast, so a guard that widens to
everyone fails here too.
"""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock

import pytest
from app.db.models import PlayerRecap
from app.player_stats import queries
from app.player_stats.recaps import ensure_recaps
from app.player_stats.service import compute_player_stats
from app.quiz.flow import QuizFlowService
from app.rooms.service import RoomError
from app.usage.tracker import UsageTracker
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from sqlalchemy import select

from tests._stats_helpers import ans, at, by_kind, event, game, store
from tests.test_rooms_pack import _create, _host
from tests.test_rooms_pack import _service as _room_service
from tests.test_shared_quiz import _finished, _h, _share, app, client  # noqa: F401

pytestmark = pytest.mark.asyncio

BAND = "kids_7_9"


# --- share link --------------------------------------------------------------


async def test_round_with_kids_is_refused_a_share_link(client, app):  # noqa: F811
    """The link would lose every question (band rows never pass the ordinary
    snapshot filter), so the server refuses with a code the app can branch on
    instead of minting an empty or different quiz."""
    session = await _finished(app, "parent", ["q1", "q2"], age_band=BAND)
    resp = await client.post(
        "/api/v1/shared-quizzes",
        json={"session_id": session.session_id},
        headers=_h("parent"),
    )
    assert resp.status_code == 409
    assert resp.json()["detail"]["code"] == "family_not_shareable"
    assert (
        await app.state.shared_quiz.store.existing(
            "parent", session_id=session.session_id, pack_id=None
        )
        is None
    ), "no link row may be left behind"


async def test_ordinary_round_still_shares(client, app):  # noqa: F811
    session = await _finished(app, "sender", ["q1", "q2"])
    share = await _share(client, "sender", session_id=session.session_id)
    assert share["kind"] == "round" and share["question_count"] == 2


# --- game together -----------------------------------------------------------


async def test_round_with_kids_cannot_become_a_room():
    service, sessions, events = _room_service()
    session = await _host(sessions, age_band=BAND)
    assert session.is_solo_only
    with pytest.raises(RoomError) as e:
        await _create(service, session, allow_pack=False)
    assert e.value.status == 422
    assert "kids" in e.value.detail
    assert (await sessions.get_session(session.session_id)).room_code is None
    assert events.names == []


async def test_ordinary_round_still_becomes_a_room():
    service, sessions, _ = _room_service()
    session = await _host(sessions)
    assert not session.is_solo_only
    room, played = await _create(service, session, allow_pack=False)
    assert played.room_code == room.room_id


# --- stats, streak, recaps ---------------------------------------------------

P = "parent-1"


def _band(result="correct", topic="family-lego", *lat):
    return ans(result, topic, "medium", "text_multichoice", *lat)


async def _stats(db, **kw):
    async with db() as s:
        return await compute_player_stats(s, [P], **kw)


async def test_round_with_kids_leaves_every_stat_card_unchanged(db_sessionmaker):
    """The parent's profile must read exactly as if the round with the kids
    never happened: same totals, games, categories, streak and speed."""
    ordinary = game(
        P,
        "own",
        at(1),
        [ans("correct", "geo", "medium", "text", 4000)] * 3
        + [ans("incorrect", "music", "hard", "text", 6000)],
        tz="UTC",
        route="carplay",
    )
    await store(db_sessionmaker, ordinary)
    before = await _stats(db_sessionmaker)

    # A long all-correct band round: it would raise answers, games, the best
    # streak (10 > 3) and add a "family-lego" category if it leaked.
    band = game(
        P, "kids", at(2), [_band("correct", "family-lego", 1500)] * 10, tz="UTC"
    )
    await store(db_sessionmaker, band)
    after = await _stats(db_sessionmaker)

    assert after == before
    totals = by_kind(after)["totals"]["data"]
    assert totals["answers"] == 4 and totals["games"] == 1


async def test_corrected_verdict_in_a_round_with_kids_stays_out(db_sessionmaker):
    """An edited transcript is re-graded and emits a newer ``answer_evaluated``
    row (``quiz/resubmission.py``) that carries the question's category again.
    That newest row is what stats keep per question, so it must be dropped by
    the same prefix, or a corrected child's answer would land in the parent's
    totals."""
    rows = game(P, "kids", at(3), [_band("incorrect")], tz="UTC")
    rows.append(
        event(
            "answer_evaluated",
            P,
            "kids",
            at(3, 12, 5),
            question_id="kids-q0",
            result="correct",
            category="family-lego",
            difficulty="medium",
            question_type="text_multichoice",
            is_regrade=True,
        )
    )
    await store(db_sessionmaker, rows)
    totals = by_kind(await _stats(db_sessionmaker))["totals"]["data"]
    assert totals == {"answers": 0, "games": 0, "minutes": 0}


async def test_answer_speed_of_a_round_with_kids_is_not_the_parents(db_sessionmaker):
    """``answer_submitted`` (sent by the app) has no category, so the overall
    median speed behind the recap's player type drops whole band sessions."""
    await store(
        db_sessionmaker,
        game(P, "own", at(1), [ans("correct", "geo", "medium", "text", 5000)] * 3)
        + game(P, "kids", at(2), [_band("correct", "family-lego", 100)] * 9),
    )
    async with db_sessionmaker() as s:
        n, median = await queries.fetch_latency_overall(s, [P], None, None)
    assert (n, median) == (3, 5000.0)


async def test_round_with_kids_alone_never_earns_a_recap(db_sessionmaker):
    """60 answers on 3 days would earn the first recap; played with the kids
    they must not, or the parent gets a recap of the children's guesses."""

    async def recaps_after(prefix: str, answer) -> list:
        rows = []
        for day in range(1, 4):
            rows += game(P, f"{prefix}{day}", at(day), [answer] * 20, tz="UTC")
        await store(db_sessionmaker, rows)
        async with db_sessionmaker() as s:
            await ensure_recaps(s, P, [P], datetime(2026, 10, 20, tzinfo=UTC))
            await s.commit()
            return (await s.execute(select(PlayerRecap.kind))).scalars().all()

    assert await recaps_after("kids", _band()) == []
    # Contrast: the same play as ordinary rounds does earn it.
    assert await recaps_after("own", ans()) == ["first"]


# --- free monthly quota ------------------------------------------------------

SUBJECT = "acct_family_quota"
LIMIT = 3


class _Now:
    def __call__(self) -> datetime:
        return datetime(2026, 11, 18, 12, 0, tzinfo=UTC)


def _question(qid: str, category: str = "family-lego") -> Question:
    return Question(
        id=qid,
        question="Which colour?",
        type="text",
        correct_answer="Red",
        topic="LEGO",
        category=category,
        difficulty="medium",
    )


def _flow(tracker: UsageTracker) -> QuizFlowService:
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "Red"}}]
    )
    served = iter(range(100))
    retriever = MagicMock()
    retriever.get = AsyncMock(side_effect=lambda qid: _question(qid))
    retriever.get_next_question = AsyncMock(
        side_effect=lambda _s: _question(f"q{next(served)}")
    )
    flow = QuizFlowService(
        session_manager=AsyncMock(),
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=tracker,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    return flow


def _session(sid: str, *, age_band: str | None, max_questions: int) -> QuizSession:
    return QuizSession(
        session_id=sid,
        user_id=SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id="q_first",
        asked_question_ids=["q_first"],
        max_questions=max_questions,
        age_band=age_band,
    )


async def _play_out(flow: QuizFlowService, session: QuizSession) -> list:
    results = []
    for _ in range(session.max_questions):
        result = await flow.process_answer(session=session, answer_text="Red")
        results.append(result)
        if result.quiz_finished or result.usage_limit_error:
            break
        session.current_question_id = result.next_question_dict["id"]
    return results


async def test_started_round_with_kids_finishes_when_the_limit_runs_out(
    db_sessionmaker,
):
    """Founder 2026-11-18: a free player with one question left plays the whole
    round (6 for 4–6). /start charged that last question; every later one is
    served without a 429 (the app would show the paywall mid-round), the
    counter stays at the limit and no credit goes below zero."""
    tracker = UsageTracker(db_sessionmaker, monthly_limit=LIMIT, now=_Now())
    for _ in range(LIMIT):  # the last free question was charged by /start
        await tracker.record_question(SUBJECT)

    session = _session("s_kids", age_band="kids_4_6", max_questions=6)
    results = await _play_out(_flow(tracker), session)

    assert all(r.usage_limit_error is None for r in results)
    assert results[-1].quiz_finished and len(results) == 6
    assert len(session.asked_question_ids) == 6
    usage = await tracker.get_usage(SUBJECT)
    assert usage["questions_used"] == LIMIT
    assert usage["remaining"] == 0
    assert usage["credit_balance"] == 0


async def test_ordinary_round_still_stops_at_the_limit(db_sessionmaker):
    """Contrast: the same situation in an ordinary quiz still ends at the wall
    with the paywall signal, so the kids' exemption cannot widen."""
    tracker = UsageTracker(db_sessionmaker, monthly_limit=LIMIT, now=_Now())
    for _ in range(LIMIT):
        await tracker.record_question(SUBJECT)

    session = _session("s_own", age_band=None, max_questions=6)
    results = await _play_out(_flow(tracker), session)

    assert len(results) == 1
    assert results[0].usage_limit_error["error"] == "quota_limit_reached"
    assert session.phase == SessionPhase.FINISHED


async def test_round_with_kids_counts_toward_the_free_questions(db_sessionmaker):
    """It is not free: under the limit each served question is charged like
    an ordinary quiz, and once the allowance is spent the next /start is
    refused as usual (check_limit is unchanged)."""
    tracker = UsageTracker(db_sessionmaker, monthly_limit=LIMIT, now=_Now())
    session = _session("s_kids", age_band=BAND, max_questions=10)
    flow = _flow(tracker)
    for _ in range(2):
        result = await flow.process_answer(session=session, answer_text="Red")
        session.current_question_id = result.next_question_dict["id"]

    assert (await tracker.get_usage(SUBJECT))["questions_used"] == 2
    await flow.process_answer(session=session, answer_text="Red")
    assert (await tracker.get_usage(SUBJECT))["questions_used"] == LIMIT
    allowed, remaining, _ = await tracker.check_limit(SUBJECT)
    assert (allowed, remaining) == (False, 0)
