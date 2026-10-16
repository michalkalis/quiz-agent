"""#208.3: the time from "player stops talking" to "Povedal si" is spent on work
that does not depend on itself, so it must not wait for itself.

TF test 2026-10-16: the founder heard 1-2 s of silence after every answer. The
next-question retrieval only needs the session, so it runs while STT and the
judge run; the confirmation read-back only needs the extracted answer, so it is
synthesized while the judge runs and rides on the response, saving the app's
own /tts/synthesize round trip. Every stage is logged (counts only) so the
founder's next drive shows where the rest of the time goes. None of it may
change what an older build sees, or cost anything when the app does not ask.
"""

from __future__ import annotations

import asyncio
import base64
import os
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402

from app.analytics.recorder import AnalyticsRecorder  # noqa: E402
from app.analytics.taxonomy import SERVER_EVENTS  # noqa: E402
from app.analytics.recorder import clean_properties  # noqa: E402
from app.api.routes import voice as voice_routes  # noqa: E402
from tests import test_answer_retry_contract as base  # noqa: E402
from tests.test_answer_retry_contract import _Q1, _Q2, _SID, _Harness, _open  # noqa: E402

client_for = base.client_for  # the fixture, re-exported for pytest

pytestmark = pytest.mark.asyncio

AUDIO = b"opus-read-back"


class _Spy(AnalyticsRecorder):
    def __init__(self):
        super().__init__(None)
        self.events: list[tuple[str, dict]] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        self.events.append((name, clean_properties(SERVER_EVENTS[name], properties)))


class _TTS:
    """Records what is synthesized; ``gate`` holds a synthesis until set."""

    def __init__(self, gate: asyncio.Event | None = None, fail: bool = False):
        self.texts: list[str] = []
        self.started = asyncio.Event()
        self.gate = gate
        self.fail = fail

    async def synthesize(self, text, voice=None, use_cache=True, billing=None):
        self.texts.append(text)
        self.started.set()
        if self.gate is not None:
            await self.gate.wait()
        if self.fail:
            raise RuntimeError("provider down")
        return AUDIO


def _harness(tts: _TTS | None = None) -> _Harness:
    h = _Harness(_open())  # graded by the judge, which these tests stub
    h.flow.analytics = _Spy()
    h.flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    h.app.state.tts_service = tts or _TTS()
    return h


async def _submit(h, client, transcript="curling", read_back=None):
    h.transcriber.text = transcript
    query = f"question_id={_Q1}&include_audio=false"
    if read_back is not None:
        query += f"&read_back={'true' if read_back else 'false'}"
    return await client.post(
        f"/api/v1/voice/submit/{_SID}?{query}",
        files={"audio": ("answer.wav", b"RIFF", "audio/wav")},
    )


async def test_next_question_retrieval_runs_while_stt_is_still_working(client_for):
    """Serial before: STT, then the retrieval, then grading. The STT stub only
    finishes once the retrieval has started, which a serial route never does."""
    h = _harness()
    retrieval_started = asyncio.Event()
    next_question = h.retriever.get_next_question.return_value

    async def _retrieve(session):
        retrieval_started.set()
        return next_question

    h.retriever.get_next_question = AsyncMock(side_effect=_retrieve)
    stt = h.transcriber.transcribe_with_quiz_context

    async def _slow_stt(**kwargs):
        await asyncio.wait_for(retrieval_started.wait(), 2)
        return await stt(**kwargs)

    h.transcriber.transcribe_with_quiz_context = _slow_stt
    client = await client_for(h)

    resp = await _submit(h, client)

    assert resp.status_code == 200
    assert h.manager.stored.current_question_id == _Q2  # the prefetched one
    h.retriever.get_next_question.assert_awaited_once()


async def test_a_rejected_recording_cancels_the_retrieval(client_for):
    """No speech = nothing advances; the retrieval must not linger or advance."""
    h = _harness()
    cancelled = asyncio.Event()

    async def _never(session):
        try:
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            cancelled.set()
            raise

    h.retriever.get_next_question = AsyncMock(side_effect=_never)
    stt = h.transcriber.transcribe_with_quiz_context

    async def _network_stt(**kwargs):
        await asyncio.sleep(0.01)  # a real recogniser awaits the network
        return await stt(**kwargs)

    h.transcriber.transcribe_with_quiz_context = _network_stt
    client = await client_for(h)

    resp = await _submit(h, client, transcript="")

    assert resp.status_code == 400
    await asyncio.wait_for(cancelled.wait(), 2)
    assert h.manager.stored.current_question_id == _Q1


async def test_read_back_is_synthesized_during_grading_and_returned(client_for):
    """The judge only finishes once the read-back synthesis has started: the two
    run side by side, and the app gets the audio with the verdict."""
    tts = _TTS()
    h = _harness(tts)

    async def _judge(**kwargs):
        await asyncio.wait_for(tts.started.wait(), 2)
        return "correct", 1.0

    h.flow.answer_evaluator.evaluate = AsyncMock(side_effect=_judge)
    client = await client_for(h)

    resp = await _submit(h, client, transcript=" curling ", read_back=True)

    assert resp.status_code == 200
    body = resp.json()
    # The app plays it only while the sheet shows exactly this text.
    assert body["read_back"]["text"] == body["evaluation"]["user_answer"]
    assert base64.b64decode(body["read_back"]["audio_base64"]) == AUDIO
    assert body["read_back"]["format"] == "opus"
    assert tts.texts == ["curling"]  # trimmed, as the app sends it


async def test_read_back_uses_the_same_text_as_the_apps_own_request(client_for):
    """Same normalisation as POST /tts/synthesize (digits spelled out in the
    quiz language), so either request's audio is the other's cache hit."""
    from app.api.routes.tts import synthesize_metered

    tts = _TTS()
    h = _harness(tts)
    h.manager.stored.language = "sk"
    client = await client_for(h)

    await _submit(h, client, transcript="366", read_back=True)
    via_submit = tts.texts[-1]
    await synthesize_metered(tts, None, None, "366", language="sk")

    assert tts.texts[-1] == via_submit != "366"


async def test_no_flag_means_no_synthesis_and_no_field(client_for):
    """Older builds never send `read_back`: no extra TTS spend, same response."""
    tts = _TTS()
    h = _harness(tts)
    client = await client_for(h)

    resp = await _submit(h, client)

    assert resp.status_code == 200
    assert resp.json()["read_back"] is None
    assert tts.texts == []


async def test_a_failing_read_back_never_costs_the_answer(client_for):
    h = _harness(_TTS(fail=True))
    client = await client_for(h)

    resp = await _submit(h, client, read_back=True)

    assert resp.status_code == 200
    assert resp.json()["evaluation"]["result"] == "correct"
    assert resp.json()["read_back"] is None


async def test_a_slow_read_back_does_not_hold_the_verdict(client_for, monkeypatch):
    """Past the short wait the field is left out and the app fetches the audio
    itself; the verdict is never held hostage by the voice provider."""
    monkeypatch.setattr(voice_routes, "READ_BACK_WAIT_S", 0.05)
    gate = asyncio.Event()
    h = _harness(_TTS(gate=gate))
    client = await client_for(h)

    resp = await asyncio.wait_for(_submit(h, client, read_back=True), 2)
    gate.set()

    assert resp.status_code == 200
    assert resp.json()["read_back"] is None


async def test_stages_are_logged_and_reach_analytics_without_the_words(
    client_for, caplog
):
    h = _harness()
    client = await client_for(h)

    with caplog.at_level("INFO"):
        resp = await _submit(h, client, transcript="Zamboni curling", read_back=True)

    assert resp.status_code == 200
    line = next(
        r.getMessage()
        for r in caplog.records
        if "Voice submit stages" in r.getMessage()
    )
    for key in ("status=200", "total_ms=", "stt_ms=", "parse_ms=", "judge_ms="):
        assert key in line
    assert "Zamboni" not in line and "curling" not in line
    (props,) = [p for n, p in h.flow.analytics.events if n == "answer_evaluated"]
    assert {"stt_ms", "parse_ms", "judge_ms"} <= props.keys()
    assert all(isinstance(props[k], int) for k in ("stt_ms", "parse_ms", "judge_ms"))


async def test_a_rejected_submit_is_logged_with_its_status(client_for, caplog):
    h = _harness()
    client = await client_for(h)

    with caplog.at_level("INFO"):
        resp = await _submit(h, client, transcript="")

    assert resp.status_code == 400
    assert any(
        "Voice submit stages" in r.getMessage() and "status=400" in r.getMessage()
        for r in caplog.records
    )
