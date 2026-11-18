"""#235.6: a game in progress whose session ran out must get a clear answer.

Why: a session lives ``ttl_minutes`` (30 by default) unless the app extends
it, and the cleanup loop deactivates stale ones on any machine. A player who
parks the car with a quiz half done comes back to an expired session. Every
request the app sends then — answer by voice or text, fetch the question or
its audio, ask for the next one, poll a game together — must answer with the
typed 404 the app already turns into "this quiz has ended", never a 500 the
app reads as "the server is broken, retry" (which retries forever).

And when the session is evicted *while* an answer is being graded, the answer
must not leave a freemium charge behind for a question that can never be
played: the advance was never stored.
"""

from __future__ import annotations

import asyncio
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402

from app.api.routes import sessions as session_routes  # noqa: E402
from app.api.routes import tts as tts_routes  # noqa: E402
from app.session.manager import SessionManager  # noqa: E402
from tests import test_answer_retry_contract as base  # noqa: E402
from tests.test_answer_retry_contract import _Q1, _SID, _Harness, _open  # noqa: E402
from tests.test_room_play import _h, game  # noqa: E402,F401 — fixture

client_for = base.client_for  # the fixture, re-exported for pytest

pytestmark = pytest.mark.asyncio

_GONE = "Session not found or expired"


async def _harness_on_real_manager(expired: bool) -> _Harness:
    """The solo routes over the real SessionManager (expiry is its job)."""
    h = _Harness(_open())
    h.flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    h.transcriber.text = "curling"
    manager = SessionManager()
    session = h.manager.stored
    session.expires_at = datetime.now(timezone.utc) + (
        timedelta(minutes=-1) if expired else timedelta(minutes=30)
    )
    await manager._store.insert(_SID, session.model_dump_json(), session.expires_at)
    h.manager = manager
    h.flow.session_manager = manager
    for router in (tts_routes.router, session_routes.router):
        h.app.include_router(router, prefix="/api/v1")
    h.app.state.tts_service = None
    h.app.state.translation_service = None
    return h


def _solo_requests(h: _Harness):
    return {
        "text answer": lambda c: h.text(c, "curling"),
        "voice answer": lambda c: h.voice(c, "curling"),
        "current question": lambda c: c.get(f"/api/v1/sessions/{_SID}/question"),
        "question audio": lambda c: c.get(f"/api/v1/sessions/{_SID}/question/audio"),
        "next question": lambda c: c.post(f"/api/v1/sessions/{_SID}/next-question"),
        "session state": lambda c: c.get(f"/api/v1/sessions/{_SID}"),
        "extend": lambda c: c.post(f"/api/v1/sessions/{_SID}/extend"),
    }


@pytest.mark.parametrize(
    "request_name",
    [
        "text answer",
        "voice answer",
        "current question",
        "question audio",
        "next question",
        "session state",
        "extend",
    ],
)
async def test_every_request_on_an_expired_game_gets_the_typed_404(
    client_for, request_name
):
    h = await _harness_on_real_manager(expired=True)
    client = await client_for(h)

    resp = await _solo_requests(h)[request_name](client)

    assert resp.status_code == 404, resp.text
    assert resp.json()["detail"] == _GONE
    h.usage.record_question.assert_not_awaited()


@pytest.mark.parametrize("minutes", [0, -30, 10**12])
async def test_extending_by_nonsense_never_ends_the_game(client_for, minutes):
    """Found by the schema fuzzer: ``minutes=0`` or less expired the very game
    it was asked to keep alive and answered 500; a huge value overflowed the
    date (500). Now a 400, and the game goes on."""
    h = await _harness_on_real_manager(expired=False)
    client = await client_for(h)

    resp = await client.post(f"/api/v1/sessions/{_SID}/extend?minutes={minutes}")

    assert resp.status_code == 400, resp.text
    assert (await client.get(f"/api/v1/sessions/{_SID}/question")).status_code == 200


async def test_a_game_evicted_by_the_cleanup_loop_answers_the_same_way(client_for):
    """The cleanup loop (any machine) deactivates the row: same typed answer."""
    h = await _harness_on_real_manager(expired=False)
    client = await client_for(h)
    assert (await client.get(f"/api/v1/sessions/{_SID}/question")).status_code == 200

    await h.manager.delete_session(_SID)  # what expire_stale does to the row

    for name, send in _solo_requests(h).items():
        resp = await send(client)
        assert resp.status_code == 404, f"{name}: {resp.text}"
        assert resp.json()["detail"] == _GONE, name


async def test_evicted_while_grading_charges_nothing_and_the_next_call_is_404(
    client_for,
):
    """The session expires during the judge call. The advance can no longer be
    stored, so the player is not charged a question they can never play, and
    the app's next request learns the game is over."""
    h = await _harness_on_real_manager(expired=False)
    judging = asyncio.Event()
    release = asyncio.Event()

    async def _slow_judge(**kwargs):
        judging.set()
        await release.wait()
        return "correct", 1.0

    h.flow.answer_evaluator.evaluate = AsyncMock(side_effect=_slow_judge)
    client = await client_for(h)

    submit = asyncio.create_task(h.text(client, "curling"))
    await asyncio.wait_for(judging.wait(), 5)
    await h.manager.delete_session(_SID)
    release.set()
    resp = await submit

    assert resp.status_code < 500, resp.text
    h.usage.record_question.assert_not_awaited()
    after = await h.text(client, "curling", question_id=_Q1)
    assert after.status_code == 404
    assert after.json()["detail"] == _GONE


# ── Games together ───────────────────────────────────────────────────────────


async def test_an_expired_game_together_tells_every_phone_it_is_gone(game):  # noqa: F811
    """Host and guests keep polling and answering after the session behind the
    room expired: each gets the room's typed 404, not a 500."""
    await game.setup()
    session = await game.sessions.get_session(game.session_id)
    session.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    await game.sessions.update_session(session)

    for who in ("host", "jana"):
        state = await game.c.get(
            f"/api/v1/rooms/{game.room_id}/state",
            headers=_h(who),
        )
        assert state.status_code == 404, state.text
        answer = await game.answer(who, "q_mcq", "b")
        assert answer.status_code == 404, answer.text
    for path in ("next", "open"):
        resp = await game.post(path, question_id="q_mcq")
        assert resp.status_code == 404, f"{path}: {resp.text}"
    assert game.usage.used["host"] == 1  # only the question served before expiry
