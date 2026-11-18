"""#232 shared quiz — one link per quiz, one play per pack, races.

Why: "play a pack once" is the guard that keeps a link from becoming a free
copy of a paid pack, so it must hold per PACK (not per link — the owner can
reach one pack from several places) and must not be burned by a start that
failed. A double tap must not mint two links, and two finishes arriving at
once (two machines, a game together) must leave one result per person without
costing any other player theirs.
"""

from __future__ import annotations

import asyncio
import uuid

import pytest
from sqlalchemy import func, select

from quiz_shared.models.participant import Participant
from quiz_shared.models.phase import SessionPhase

from app.db.models import SharedQuiz, SharedQuizResult

from tests.test_shared_quiz import (  # noqa: F401 — fixtures
    PACK,
    _finished,
    _session,
    _share,
    _start,
    app,
    client,
)

pytestmark = pytest.mark.asyncio


async def _count(db, model, *where):
    async with db() as s:
        return (
            await s.execute(select(func.count()).select_from(model).where(*where))
        ).scalar_one()


async def test_one_link_per_pack_and_play_once_spans_every_link(
    client,  # noqa: F811
    app,  # noqa: F811
    db_sessionmaker,
):
    by_pack = await _share(client, "owner", pack_id=PACK)
    session = await _finished(app, "owner", ["p1", "p2"], pack_id=PACK)
    by_session = await _share(client, "owner", session_id=session.session_id)
    assert by_session["token"] == by_pack["token"]
    # A second link to the same pack (made before this rule, or by a co-owner
    # of a copy): having played one, the friend cannot play it through another.
    async with db_sessionmaker() as s:
        s.add(
            SharedQuiz(
                id=uuid.uuid4(),
                token="tok-second-link",
                kind="pack",
                language="sk",
                question_ids=["p1", "p2"],
                pack_id=uuid.UUID(PACK),
                sender_subject_id="co-owner",
            )
        )
        await s.commit()
    assert (await _start(client, by_pack["token"], "friend")).status_code == 200
    assert (await _start(client, "tok-second-link", "friend")).status_code == 409


async def test_a_failed_start_does_not_use_up_the_pack_play(client, app):  # noqa: F811
    token = (await _share(client, "owner", pack_id=PACK))["token"]
    sessions = app.state.session_manager
    real = sessions.create_session
    sessions.create_session = _fail_once(real)
    with pytest.raises(RuntimeError):
        await app.state.shared_quiz.start(token, "friend")
    sessions.create_session = real
    resp = await _start(client, token, "friend")
    assert resp.status_code == 200
    assert (await _session(app, resp)).fixed_question_ids == ["p1", "p2"]


def _fail_once(real):
    calls = []

    async def create_session(**kw):
        calls.append(kw)
        if len(calls) == 1:
            raise RuntimeError("store down")
        return await real(**kw)

    return create_session


async def test_double_tap_makes_one_link(app, db_sessionmaker):  # noqa: F811
    svc = app.state.shared_quiz
    session = await _finished(app, "sender", ["q1", "q2"])
    a, b = await asyncio.gather(
        svc.create("sender", session_id=session.session_id),
        svc.create("sender", session_id=session.session_id),
    )
    p, q = await asyncio.gather(
        svc.create("owner", pack_id=PACK), svc.create("owner", pack_id=PACK)
    )
    assert a.token == b.token and p.token == q.token
    assert await _count(db_sessionmaker, SharedQuiz) == 2


async def test_concurrent_finishes_keep_one_result_per_person(
    client,  # noqa: F811
    app,  # noqa: F811
    db_sessionmaker,
):
    svc = app.state.shared_quiz
    session = await _finished(app, "sender", ["q1", "q2"])
    token = (await _share(client, "sender", session_id=session.session_id))["token"]
    share = await svc.store.by_token(token)
    # A game together that nobody "started" from the link (no reserved rows),
    # finished twice at once; one player's write fails.
    room = await _finished(app, "host", ["q1", "q2"], shared_quiz_id=str(share.id))
    room.mode = "multiplayer"
    room.participants = [
        Participant(participant_id="p1", user_id="host", display_name="Ana", score=2),
        Participant(participant_id="p2", user_id="boom", display_name="Bo", score=1),
        Participant(participant_id="p3", user_id="guest", display_name="Cy", score=0),
    ]
    room.phase = SessionPhase.FINISHED
    real = svc.store.record_result

    async def flaky(share_id, subject_id, **kw):
        if subject_id == "boom":
            raise RuntimeError("write failed")
        return await real(share_id, subject_id, **kw)

    svc.store.record_result = flaky
    await asyncio.gather(svc.finish(room), svc.finish(room), svc.finish(room))
    rows = await _count(db_sessionmaker, SharedQuizResult)
    assert rows == 2  # host + guest, each once; "boom" did not stop the guest
