"""#205 205.1–205.3 against the real Postgres schema.

Why: everyone in a language must get the same five questions all day (the set is
persisted, not recomputed); a player gets one attempt per date and their first
verdict is what counts; "others" never includes the player; rank is real and
top-half only; and erasing an account removes its plays from the crowd.
"""

from datetime import date

import pytest
from sqlalchemy import select

from app.auth.account_service import _erase_personal_trail
from app.daily_challenge.service import DailyChallengeService, DailySetUnavailable
from app.db.models import AnonymousIdentity, DailyChallengeAnswer, DailyChallengePlay
from app.usage.account_merge import _fold_daily_challenges
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

DAY = date(2026, 10, 15)


def _q(i, type_="text"):
    return Question(
        id=f"q{i}",
        question=f"Question {i}?",
        type=type_,
        correct_answer="b" if type_ == "text_multichoice" else f"Answer {i}",
        possible_answers={"a": "A", "b": f"Option {i}"}
        if type_ == "text_multichoice"
        else None,
        topic="t",
        category=f"c{i}",
        difficulty="medium",
        language="en",
    )


class FakeRetriever:
    def __init__(self, n=12):
        self.pool = [_q(i) for i in range(n)] + [_q(100, "text_multichoice")]
        self.calls = 0

    async def daily_candidates(self, language, n=300):
        self.calls += 1
        return list(self.pool)

    async def get(self, qid):
        return next((q for q in self.pool if q.id == qid), None)

    async def get_translations(self, ids, language, statuses=("approved",)):
        return {}


def _session(subject, set_day=DAY, language="en"):
    return QuizSession(
        session_id=f"s-{subject}",
        user_id=subject,
        language=language,
        daily_challenge_date=set_day.isoformat(),
    )


async def _start(svc, subject, language="en"):
    play, remaining = await svc.begin(subject, language, DAY)
    session = _session(subject, language=language)
    await svc.attach_session(play.id, session.session_id)
    return session, remaining


async def _play_all(svc, subject, verdicts, language="en"):
    session, remaining = await _start(svc, subject, language)
    for qid, verdict in zip(remaining, verdicts):
        await svc.record_answer(session, qid, verdict)
    await svc.finish(session)
    return remaining


async def test_set_is_persisted_once_and_shared(db_sessionmaker):
    retriever = FakeRetriever()
    svc = DailyChallengeService(db_sessionmaker, retriever)
    first = await svc.question_ids("en", DAY)
    retriever.pool.reverse()  # the corpus changes later that day
    assert await svc.question_ids("en", DAY) == first
    assert retriever.calls == 1
    assert len(first) == 5
    # Another language gets its own set; the next day avoids today's questions.
    assert set(await svc.question_ids("en", date(2026, 10, 16))).isdisjoint(first)


async def test_too_few_questions_fails_loud(db_sessionmaker):
    retriever = FakeRetriever(n=2)
    svc = DailyChallengeService(db_sessionmaker, retriever)
    with pytest.raises(DailySetUnavailable):
        await svc.question_ids("en", DAY)


async def test_one_attempt_per_date_and_resume_skips_answered(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    session, remaining = await _start(svc, "anon-a")
    await svc.record_answer(session, remaining[0], "correct")
    # Interrupted: a second start resumes with the four unanswered questions.
    _, again = await _start(svc, "anon-a")
    assert again == remaining[1:]
    for qid in again:
        await svc.record_answer(_session("anon-a"), qid, "incorrect")
    await svc.finish(_session("anon-a"))
    # Finished: nothing left to play, in any language.
    _, after = await svc.begin("anon-a", "sk", DAY)
    assert after == []
    state = await svc.state("anon-a", "en", DAY)
    assert state.status == "played" and state.summary.score == 1


async def test_first_verdict_wins_but_a_corrected_transcript_regrades(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    session, remaining = await _start(svc, "anon-a")
    await svc.record_answer(session, remaining[0], "incorrect")
    # A second first-submission (e.g. another live session) cannot overwrite it.
    await svc.record_answer(session, remaining[0], "correct")
    async with db_sessionmaker() as db:
        rows = (await db.execute(select(DailyChallengeAnswer))).scalars().all()
    assert [(r.result, r.knew) for r in rows] == [("incorrect", False)]
    for qid in remaining[1:]:
        await svc.record_answer(session, qid, "incorrect")
    await svc.finish(session)
    assert (await svc.state("anon-a", "en", DAY)).summary.score == 0
    # An edited transcript of the last answer (#189) re-grades the finished play.
    await svc.record_answer(session, remaining[0], "correct", regrade=True)
    state = await svc.state("anon-a", "en", DAY)
    assert state.summary.score == 1 and state.summary.marks[0] is True


async def test_first_player_then_live_numbers_exclude_self(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    ids = await _play_all(
        svc, "p1", ["correct", "correct", "incorrect", "correct", "correct"]
    )

    alone = await svc.state("p1", "en", DAY)
    assert alone.summary.comparison == "Nobody played before you today."
    assert alone.summary.best_hit is None  # no crowd yet, nothing to compare
    assert alone.summary.marks == [True, True, False, True, True]

    # A second player misses the first question and gets 2 of 5.
    await _play_all(
        svc, "p2", ["incorrect", "correct", "correct", "incorrect", "incorrect"]
    )
    crowd = await svc.crowd("en", DAY, ids[0], exclude=["p1"])
    assert (crowd.others, crowd.knew) == (1, 0)

    live = await svc.state("p1", "en", DAY)
    assert live.summary.players == 2
    assert live.summary.comparison == "Best score of 2 players."
    assert live.summary.rank == "Best score of 2 players."
    best = live.summary.best_hit
    assert best.question_id in (ids[0], ids[3], ids[4]) and best.rare
    assert best.text == "Nobody else knew that."

    # The weaker player sees no rank, never "worse than".
    weak = await svc.state("p2", "en", DAY)
    assert weak.summary.rank is None
    assert weak.summary.comparison == "Tough challenge."


async def test_answer_strip_and_spoken_cap(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    ids = await _play_all(svc, "p1", ["incorrect"] * 5)
    session, _ = await _start(svc, "p2")
    spoken = []
    for qid in ids[:2]:
        strip, line = await svc.answer_strip(session, qid, "correct")
        assert strip.kind == "rare" and strip.text == "Nobody else knew that."
        spoken.append(line)
    # A re-grade shows the strip again but never speaks again.
    strip, line = await svc.answer_strip(session, ids[1], "correct", regrade=True)
    assert strip is not None and line is None
    # Resumed in a new session: the count of spoken lines carries over.
    resumed, _ = await _start(svc, "p2")
    for qid in ids[2:]:
        _, line = await svc.answer_strip(resumed, qid, "correct")
        spoken.append(line)
    assert [s is not None for s in spoken] == [True, True, True, False, False]


async def test_wrong_easy_has_no_strip(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    ids = await _play_all(svc, "p1", ["correct"] * 5)
    session, _ = await _start(svc, "p2")
    strip, line = await svc.answer_strip(session, ids[0], "incorrect")
    assert strip is None and line is None


async def test_erase_removes_plays_from_the_crowd(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    ids = await _play_all(svc, "p1", ["correct"] * 5)
    async with db_sessionmaker() as db:
        await _erase_personal_trail(db, ["p1"])
        await db.commit()
        assert (await db.execute(select(DailyChallengeAnswer))).first() is None
    crowd = await svc.crowd("en", DAY, ids[0], exclude=["someone"])
    assert crowd.others == 0


async def _sign_in(db_sessionmaker, anon, user):
    async with db_sessionmaker() as db:
        db.add(AnonymousIdentity(anon_id=anon, upgraded_to_user_id=user))
        await _fold_daily_challenges(db, anon, user)
        await db.commit()


async def test_sign_in_moves_the_play_and_sign_out_cannot_replay_the_day(
    db_sessionmaker,
):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    await _play_all(svc, "anon-1", ["correct"] * 5)
    await _sign_in(db_sessionmaker, "anon-1", "user-1")
    async with db_sessionmaker() as db:
        subjects = (await db.execute(select(DailyChallengePlay.subject_id))).scalars()
        assert list(subjects) == ["user-1"]
    assert (await svc.state("user-1", "en", DAY)).status == "played"
    # Signed out: the device is the anon again, and the day is still played.
    _, remaining = await svc.begin("anon-1", "en", DAY)
    assert remaining == []
    assert (await svc.state("anon-1", "en", DAY)).status == "played"


async def test_signing_in_mid_challenge_keeps_recording_the_live_session(
    db_sessionmaker,
):
    svc = DailyChallengeService(db_sessionmaker, FakeRetriever())
    session, remaining = await _start(svc, "anon-2")
    await svc.record_answer(session, remaining[0], "correct")
    await _sign_in(db_sessionmaker, "anon-2", "user-2")
    for qid in remaining[1:]:
        await svc.record_answer(session, qid, "correct")  # session still says anon-2
    await svc.finish(session)
    state = await svc.state("user-2", "en", DAY)
    assert state.status == "played" and state.summary.score == 5
