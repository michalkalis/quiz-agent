"""#249.5: players answer a typed-answer question of a game together by voice.

Why it matters: the founder wants the microphone for everyone, transcribed on
the server exactly like a solo voice answer. The answer clock is shared, so a
recording that ends at the buzzer must count from when it ARRIVED: if the
transcription time (a second or two) made it late, the last word of every
close race would be lost. A recording nobody could hear, or a recogniser
failure, must store nothing and never stall the room; each player still
answers once; a paused question keeps taking answers; the solo size cap holds.
"""

from __future__ import annotations

import asyncio
import io

import pytest

from app.rooms import rounds
from app.voice import transcriber as transcriber_module
from app.voice.transcriber import TranscriptionResult, VoiceTranscriber

from .test_room_play import _h, game  # noqa: F401  (fixture)

pytestmark = pytest.mark.asyncio

GRACE = rounds.ANSWER_GRACE.total_seconds()


class Recogniser:
    """Stands in for the OpenAI call only: the real VoiceTranscriber still
    checks format and size, primes with the question and passes the language."""

    def __init__(self, clock):
        self.clock = clock
        self.calls: list[dict] = []
        self.text = "Paris"
        self.fail = False
        self.takes = 0.0  # seconds the transcription "takes" on the clock
        self.hold: asyncio.Event | None = None
        self.started = asyncio.Event()

    async def __call__(self, **kwargs) -> TranscriptionResult:
        self.calls.append(kwargs)
        self.started.set()
        if self.hold is not None:
            await self.hold.wait()
        self.clock.tick(self.takes)
        if self.fail:
            raise RuntimeError("provider down")
        return TranscriptionResult(
            text=self.text,
            language=kwargs.get("language"),
            no_speech_prob=0.0,
            avg_logprob=0.0,
            duration=1.0,
        )


@pytest.fixture
def voice(game, monkeypatch):  # noqa: F811
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    monkeypatch.setattr(transcriber_module, "TRANSIENT_RETRY_BACKOFF_S", 0)
    t = VoiceTranscriber()
    rec = Recogniser(game.clock)
    t._transcribe_openai = rec
    game.c._transport.app.state.voice_transcriber = t
    return rec


async def _to_open_question(game):  # noqa: F811
    """Everyone answers the A–D question, the host moves on to the open one
    and finishes reading it: the answer clock starts now."""
    await game.setup(thinking_seconds=10)
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    await game.post("next")
    await game.post("open", question_id="q_open")
    return (await game.state())["round"]["remaining_ms"] / 1000


async def _speak(game, who="jana", qid="q_open", audio=b"RIFF....WAVE" + b"\0" * 64):  # noqa: F811
    return await game.c.post(
        f"/api/v1/rooms/{game.room_id}/answer/voice",
        data={"question_id": qid},
        files={"audio": ("answer.wav", io.BytesIO(audio), "audio/wav")},
        headers=_h(who),
    )


async def _current(game):  # noqa: F811
    session = await game.sessions.get_session(game.session_id)
    return session.room_game.current


async def test_a_spoken_answer_is_stored_like_a_typed_one_and_graded(game, voice):  # noqa: F811
    await _to_open_question(game)
    r = await _speak(game)
    assert r.status_code == 200, r.text
    assert r.json()["round"]["your_answer"] == "Paris"
    # Same recogniser inputs as solo: the session language and the question
    # as context, never its answer.
    call = voice.calls[0]
    assert call["language"] == "en" and "capital of France" in call["prompt"]
    assert "Paris" not in call["prompt"]
    for who in ("host", "peto"):
        await game.answer(who, "q_open", "Lyon")
    rnd = (await game.state("jana"))["round"]
    assert rnd["phase"] == "revealed"
    points = {r["participant_id"]: r["points"] for r in rnd["results"]}
    assert points[await game.pid("jana")] == 1.0
    # Analytics: the same answer_evaluated row as a typed answer, route=voice.
    routes = {
        p["route"]
        for name, subject, p in game.events.rows
        if name == "answer_evaluated" and p["question_id"] == "q_open"
        if subject == "jana"
    }
    assert routes == {"voice"}


async def test_a_recording_that_arrives_within_the_grace_counts_however_long_stt_takes(
    game,  # noqa: F811
    voice,
):
    left = await _to_open_question(game)
    # The recording lands just inside the grace, then STT takes 5 s.
    game.clock.tick(left + GRACE - 0.1)
    voice.hold = asyncio.Event()
    upload = asyncio.create_task(_speak(game))
    await voice.started.wait()
    game.clock.tick(5)
    # Meanwhile every phone polls: the question must not close without her.
    state = await game.state("peto")
    assert state["round"]["phase"] == "grading"
    await game.settle()
    assert (await _current(game)).closed is False
    # Nor can anyone sneak a typed answer in now that the time is up.
    assert (await game.answer("peto", "q_open", "Paris")).status_code == 409
    voice.hold.set()
    r = await upload
    assert r.status_code == 200, r.text
    # With the held recording in, the next poll closes and grades it.
    await game.state()
    await game.settle()
    rnd = (await game.state("jana"))["round"]
    assert rnd["phase"] == "revealed"
    assert any(x["answer"] == "Paris" for x in rnd["results"])


async def test_a_recording_that_arrives_after_the_grace_is_refused_before_stt(
    game,  # noqa: F811
    voice,
):
    left = await _to_open_question(game)
    game.clock.tick(left + GRACE + 0.1)
    r = await _speak(game)
    assert r.status_code == 409
    assert voice.calls == [], "nothing is paid for a late recording"


async def test_nothing_heard_stores_nothing_and_the_player_may_try_again(game, voice):  # noqa: F811
    await _to_open_question(game)
    voice.text = ""
    r = await _speak(game)
    assert r.status_code == 400 and r.json()["detail"]["code"] == "no_speech"
    current = await _current(game)
    assert current.answers == {} and current.voice_pending == {}
    failed = [p for n, _, p in game.events.rows if n == "transcription_failed"]
    assert failed and failed[-1]["multiplayer"] is True
    # Time is left: she says it again and it counts.
    voice.text = "Paris"
    assert (await _speak(game)).status_code == 200


async def test_a_recogniser_failure_is_a_clear_error_and_never_stalls_the_room(
    game,  # noqa: F811
    voice,
):
    left = await _to_open_question(game)
    voice.fail = True
    r = await _speak(game)
    assert r.status_code == 502 and r.json()["detail"]["code"] == "stt_error"
    current = await _current(game)
    assert current.answers == {} and current.voice_pending == {}
    # Nothing is held, so the question closes on time as usual.
    game.clock.tick(left + GRACE + 0.1)
    await game.state()
    await game.settle()
    assert (await game.state("jana"))["round"]["phase"] == "revealed"


async def test_one_answer_per_player_voice_after_typed_is_409(game, voice):  # noqa: F811
    await _to_open_question(game)
    assert (await game.answer("jana", "q_open", "Paris")).status_code == 200
    r = await _speak(game)
    assert r.status_code == 409
    assert voice.calls == []


async def test_typed_while_a_recording_is_in_flight_is_409(game, voice):  # noqa: F811
    # The auto-send of a typed draft at the buzzer must never become a second
    # answer next to the recording being transcribed.
    await _to_open_question(game)
    voice.hold = asyncio.Event()
    upload = asyncio.create_task(_speak(game))
    await voice.started.wait()
    assert (await game.answer("jana", "q_open", "Lyon")).status_code == 409
    voice.hold.set()
    assert (await upload).status_code == 200
    assert (await _current(game)).answers[await game.pid("jana")].answer == "Paris"


async def test_a_paused_question_still_takes_a_spoken_answer(game, voice):  # noqa: F811
    left = await _to_open_question(game)
    game.clock.tick(left - 1)
    await game.post("pause", paused=True)
    game.clock.tick(120)
    assert (await _speak(game)).status_code == 200


async def test_a_stale_hold_from_a_crashed_request_does_not_stall_the_room(game, voice):  # noqa: F811
    left = await _to_open_question(game)
    session = await game.sessions.get_session(game.session_id)
    session.room_game.current.voice_pending[await game.pid("jana")] = rounds.now()
    await game.sessions.update_session(session)
    game.clock.tick(left + GRACE + rounds.VOICE_PENDING_MAX.total_seconds())
    await game.state()
    await game.settle()
    assert (await game.state())["round"]["phase"] == "revealed"


async def test_the_solo_size_cap_holds(game, voice):  # noqa: F811
    await _to_open_question(game)
    big = b"\0" * (VoiceTranscriber.MAX_FILE_SIZE + 1)
    r = await _speak(game, audio=big)
    assert r.status_code == 400
    assert voice.calls == []
    assert (await _current(game)).voice_pending == {}


async def test_an_option_question_is_tapped_not_spoken(game, voice):  # noqa: F811
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    r = await _speak(game, qid="q_mcq")
    assert r.status_code == 422 and voice.calls == []
