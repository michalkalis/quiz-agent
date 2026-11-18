"""#235.6: an answer whose request dies part-way must still count exactly once.

Why: a player in a car loses signal all the time, and a deploy stops the
process under requests in flight. The app retries the same submit (same
``question_id``) once it is back. Whatever point the first request died at,
the player must end up with ONE verdict for the question, ONE freemium question
charged and ONE advance — never a second charge for an answer they gave once,
never a question skipped, never a half-written session.

Three ways a request dies, each pinned here:

- the upload is cut before the server has the whole recording: nothing may
  have happened yet (no paid transcription, no grade, no charge);
- the client goes away after the upload: the server finishes the work anyway
  (uvicorn does not cancel a handler), so the retry is the free replay;
- the handler itself is cancelled or killed mid-flight (deploy, crash) at any
  await: the retry must grade and charge as if the first never happened, or
  replay what the first one committed.
"""

from __future__ import annotations

import asyncio
import os
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import httpx  # noqa: E402
import pytest  # noqa: E402

from tests import test_answer_retry_contract as base  # noqa: E402
from tests.test_answer_retry_contract import _Q1, _Q2, _SID, _Harness, _open  # noqa: E402

client_for = base.client_for  # the fixture, re-exported for pytest

pytestmark = pytest.mark.asyncio

_VOICE_PATH = f"/api/v1/voice/submit/{_SID}"
_VOICE_QUERY = f"question_id={_Q1}&include_audio=false"


def _harness() -> _Harness:
    h = _Harness(_open())
    h.flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    h.retriever.get_translations = AsyncMock(return_value={})
    h.transcriber.text = "curling"
    return h


def _assert_counted_once(h: _Harness) -> None:
    """One verdict, one charge, one advance — the whole point of these tests."""
    s = h.manager.stored
    assert s.current_question_id == _Q2
    assert s.asked_question_ids == [_Q1, _Q2]
    assert s.last_evaluation.question_id == _Q1
    assert s.participants[0].answered_count == 1
    assert s.participants[0].score == 1.0
    assert h.usage.record_question.await_count == 1


def _assert_untouched(h: _Harness) -> None:
    s = h.manager.stored
    assert s.current_question_id == _Q1
    assert s.asked_question_ids == [_Q1]
    assert s.last_evaluation is None
    assert s.participants[0].answered_count == 0
    h.usage.record_question.assert_not_awaited()


def _voice_upload() -> tuple[list[tuple[bytes, bytes]], bytes]:
    """The exact multipart bytes and headers the app sends for one recording."""
    request = httpx.Request(
        "POST",
        f"http://test{_VOICE_PATH}?{_VOICE_QUERY}",
        files={"audio": ("answer.wav", b"RIFF" + b"\0" * 4096, "audio/wav")},
    )
    body = request.read()
    headers = [(k.lower(), v) for k, v in request.headers.raw]
    return headers, body


async def _drive_raw(app, headers, body_messages: list[dict]) -> list[dict]:
    """Run one voice submit through the ASGI app the way uvicorn does when the
    client drops: the body arrives as ``body_messages``, every later
    ``receive`` reports the disconnect, and whatever the app sends after that
    goes nowhere (uvicorn ignores sends on a closed connection)."""
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": _VOICE_PATH,
        "raw_path": _VOICE_PATH.encode(),
        "query_string": _VOICE_QUERY.encode(),
        "root_path": "",
        "headers": [(b"host", b"test"), *headers],
        "client": ("127.0.0.1", 50000),
        "server": ("test", 80),
    }
    pending = list(body_messages)
    sent: list[dict] = []

    async def receive():
        if pending:
            return pending.pop(0)
        return {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    await app(scope, receive, send)
    return sent


# ── The upload is cut ────────────────────────────────────────────────────────


async def test_upload_cut_mid_recording_pays_and_counts_nothing(client_for):
    """Half a recording is not an answer: no transcription is paid for and the
    question stays open, so the app's retry is a normal first answer."""
    h = _harness()
    stt = AsyncMock(wraps=h.transcriber.transcribe_with_quiz_context)
    h.transcriber.transcribe_with_quiz_context = stt
    headers, body = _voice_upload()

    await _drive_raw(
        h.app,
        headers,
        [{"type": "http.request", "body": body[: len(body) // 2], "more_body": True}],
    )

    stt.assert_not_awaited()
    _assert_untouched(h)

    client = await client_for(h)
    retry = await h.voice(client, "curling")
    assert retry.status_code == 200
    assert retry.json()["evaluation"]["question_id"] == _Q1
    _assert_counted_once(h)


# ── The client goes away after the upload ───────────────────────────────────


async def test_client_gone_after_upload_still_lands_once_and_the_retry_replays(
    client_for,
):
    """The tunnel case on the voice route: the answer was uploaded, the reply
    never arrived. The server must finish grading (the player did answer), and
    the app's retry must be the free replay of that verdict — not a second
    grade of the question that came next, not a second charge."""
    h = _harness()
    headers, body = _voice_upload()

    sent = await _drive_raw(h.app, headers, [{"type": "http.request", "body": body}])

    assert sent and sent[0]["status"] == 200  # finished, even if nobody heard
    _assert_counted_once(h)
    judged = h.flow.answer_evaluator.evaluate.await_count

    client = await client_for(h)
    retry = await h.voice(client, "curling")

    assert retry.status_code == 200
    assert retry.json()["evaluation"]["question_id"] == _Q1
    assert retry.json()["current_question"]["id"] == _Q2
    assert h.flow.answer_evaluator.evaluate.await_count == judged
    _assert_counted_once(h)


# ── The handler dies mid-flight ─────────────────────────────────────────────


class _Hang:
    """Parks the FIRST call at one await of the submit; later calls (the
    retry) pass straight through to ``then``."""

    def __init__(self, then):
        self.then = then
        self.reached = asyncio.Event()
        self._armed = True

    async def __call__(self, *args, **kwargs):
        if self._armed:
            self._armed = False
            self.reached.set()
            await asyncio.Event().wait()  # until cancelled
        return await self.then(*args, **kwargs)


def _hang_at(h: _Harness, stage: str) -> _Hang:
    if stage == "transcription":
        hang = _Hang(h.transcriber.transcribe_with_quiz_context)
        h.transcriber.transcribe_with_quiz_context = hang
    elif stage == "grading":
        hang = _Hang(h.flow.answer_evaluator.evaluate)
        h.flow.answer_evaluator.evaluate = hang
    elif stage == "serving_next_question":
        # After the answer is graded and the next question picked, its text is
        # resolved for the session language (a corpus lookup, or a paid
        # translation call) before the session is written. A Slovak session
        # spends real time here.
        h.manager.stored.language = "sk"
        hang = _Hang(AsyncMock(return_value={}))
        h.retriever.get_translations = hang
    else:  # pragma: no cover
        raise AssertionError(stage)
    return hang


_STAGES = [
    ("text", "grading"),
    ("text", "serving_next_question"),
    ("voice", "transcription"),
    ("voice", "grading"),
    ("voice", "serving_next_question"),
]


@pytest.mark.parametrize("route,stage", _STAGES, ids=[f"{r}-{s}" for r, s in _STAGES])
async def test_a_submit_killed_mid_flight_is_counted_once_after_the_retry(
    client_for, route, stage
):
    """Whatever await the first request died at, the retry leaves the player
    with exactly one verdict, one charge and one advance."""
    h = _harness()
    hang = _hang_at(h, stage)
    client = await client_for(h)
    submit = getattr(h, route)

    first = asyncio.create_task(submit(client, "curling"))
    await asyncio.wait_for(hang.reached.wait(), 5)
    first.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first

    retry = await submit(client, "curling")

    assert retry.status_code == 200, retry.text
    assert retry.json()["evaluation"]["question_id"] == _Q1
    assert retry.json()["current_question"]["id"] == _Q2
    _assert_counted_once(h)
