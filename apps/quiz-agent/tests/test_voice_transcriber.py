"""Answer STT on OpenAI gpt-transcribe only (#208.1).

Replaying the 2026-10-16 car test, ElevenLabs Scribe missed answers that
gpt-transcribe primed with the question heard, so gpt-transcribe became the
only answer recogniser. With no second provider behind it, these tests pin what
keeps a player's answer from being lost anyway: a transient provider failure is
retried once (and only once, so a real outage fails fast), an empty primed
transcript gets one unprimed decoding, plus the request shape (`languages`,
`keywords`), the upload cap, log privacy and the whisper-1 rollback.
"""

from __future__ import annotations

import io
from unittest.mock import AsyncMock

import httpx
import openai
import pytest

from app.voice import transcriber as transcriber_module
from app.voice.transcriber import VoiceTranscriber, sanitize_keyterms

pytestmark = pytest.mark.asyncio


def _resp(**attrs):
    return type("Resp", (), attrs)()


def _stub(t: VoiceTranscriber, *, side_effect=None, **response_attrs) -> AsyncMock:
    """Replace the OpenAI client on an instance so no network call is made."""
    create = AsyncMock(side_effect=side_effect, return_value=_resp(**response_attrs))
    t.client = type(
        "C",
        (),
        {
            "audio": type(
                "A", (), {"transcriptions": type("T", (), {"create": create})()}
            )()
        },
    )()
    return create


def _transient() -> Exception:
    return openai.APIConnectionError(request=httpx.Request("POST", "https://x"))


@pytest.fixture(autouse=True)
def env(monkeypatch):
    """VoiceTranscriber builds an OpenAI client eagerly; no call is ever made."""
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    monkeypatch.setattr(transcriber_module, "TRANSIENT_RETRY_BACKOFF_S", 0)


async def test_a_transient_failure_is_retried_once_and_the_answer_survives():
    """With no second provider, a dropped connection must not cost the answer."""
    t = VoiceTranscriber()
    create = _stub(t, side_effect=[_transient(), _resp(text="Paríž ")])

    result = await t.transcribe(io.BytesIO(b"x"), "answer.wav", language="sk")

    assert result.text == "Paríž"
    assert create.await_count == 2


async def test_a_second_transient_failure_reaches_the_existing_error_path():
    """Exactly one retry: a real outage fails fast into the route's error path
    instead of holding the player on "processing"."""
    t = VoiceTranscriber()
    create = _stub(t, side_effect=[_transient(), _transient(), _resp(text="late")])

    with pytest.raises(RuntimeError, match="Transcription failed"):
        await t.transcribe(io.BytesIO(b"x"), "answer.wav")
    assert create.await_count == 2


async def test_a_bad_request_is_not_retried():
    """A 400 would fail identically again; retrying only adds latency."""
    t = VoiceTranscriber()
    bad = openai.BadRequestError(
        "bad",
        response=httpx.Response(400, request=httpx.Request("POST", "https://x")),
        body=None,
    )
    create = _stub(t, side_effect=bad)

    with pytest.raises(RuntimeError, match="Transcription failed"):
        await t.transcribe(io.BytesIO(b"x"), "answer.wav")
    assert create.await_count == 1


async def test_the_sdk_does_not_retry_on_its_own():
    """The single retry above is the whole budget; the SDK's default two
    retries with backoff would stack up to seconds of silence on top."""
    assert VoiceTranscriber().client.max_retries == 0


async def test_an_empty_primed_transcript_gets_one_unprimed_decoding():
    """2026-10-16 replay: primed with the question, gpt-transcribe returned
    nothing for clearly spoken answers that the unprimed decoding heard."""
    t = VoiceTranscriber()
    create = _stub(t, side_effect=[_resp(text=""), _resp(text="Reset hesla.")])

    result = await t.transcribe_with_quiz_context(
        io.BytesIO(b"x"), "answer.wav", current_question="Čo robí IT?", language="sk"
    )

    assert result.text == "Reset hesla."
    first, second = (c.kwargs for c in create.await_args_list)
    assert "Čo robí IT?" in first["prompt"]
    assert "prompt" not in second


async def test_a_heard_answer_costs_exactly_one_call():
    t = VoiceTranscriber()
    create = _stub(t, text="Váh")

    await t.transcribe_with_quiz_context(
        io.BytesIO(b"x"), "answer.wav", current_question="Rieka?", language="sk"
    )

    assert create.await_count == 1


async def test_gpt_transcribe_gets_keywords_and_languages_never_language():
    """#204.1: sending `language` to gpt-transcribe was a request bug; MCQ
    options are the hints that make a noisy "modrá" land on the right option."""
    t = VoiceTranscriber()
    create = _stub(t, text="modrá")

    await t.transcribe(
        io.BytesIO(b"x"), "a.wav", language="sk", keyterms=["modrá", "zelená<x>"]
    )

    kwargs = create.await_args.kwargs
    assert kwargs["model"] == "gpt-transcribe"
    assert kwargs["response_format"] == "json"
    assert "language" not in kwargs
    assert "temperature" not in kwargs  # the first pass is the default decoding
    assert kwargs["extra_body"] == {
        "languages": ["sk"],
        "keywords": ["modrá", "zelená x"],
    }


async def test_keyterm_sanitising_drops_what_the_api_rejects():
    """One malformed MCQ option must not fail the whole transcription."""
    terms = sanitize_keyterms(
        [
            "Bratislava",
            "bratislava",  # dedupe, case-insensitive
            "",
            "Mexiko <City>",  # forbidden chars stripped, still valid
            "one two three four five six",  # > 5 words
            "x" * 60,  # > 49 chars
        ]
    )
    assert terms == ["Bratislava", "Mexiko City"]
    assert len(sanitize_keyterms([f"term {i}" for i in range(1500)])) == 1000


async def test_transcript_text_is_not_logged_only_its_length(caplog):
    """#193: INFO ships to Sentry Logs; diagnostics need the length, not the words."""
    t = VoiceTranscriber()
    _stub(t, text="Bratislava")

    with caplog.at_level("INFO"):
        await t.transcribe(io.BytesIO(b"x"), "answer.wav")

    line = next(
        r.getMessage()
        for r in caplog.records
        if "Transcribed provider=" in r.getMessage()
    )
    assert "Bratislava" not in line
    assert "chars=10" in line


async def test_oversized_audio_is_rejected_before_any_stt_call():
    """#193: STT bills per audio minute; an upload far beyond any real answer is
    refused as a client fault before anything is paid for."""
    from app.quiz.errors import InvalidSubmission

    t = VoiceTranscriber()
    create = _stub(t, text="x")

    oversized = io.BytesIO(b"\0" * (VoiceTranscriber.MAX_FILE_SIZE + 1))
    with pytest.raises(InvalidSubmission, match="File too large"):
        await t.transcribe(oversized, "answer.wav")
    create.assert_not_awaited()


async def test_longest_real_ios_answer_fits_under_the_cap():
    """The iOS answer buffer holds at most 20 s of 16-bit mono PCM at 48 kHz."""
    t = VoiceTranscriber()
    _stub(t, text="Paris")
    worst_case = io.BytesIO(b"\0" * (20 * 48_000 * 2 + 44))

    assert (await t.transcribe(worst_case, "answer.wav")).text == "Paris"


async def test_whisper_rollback_keeps_segment_metrics(monkeypatch):
    """`STT_MODEL=whisper-1` must restore verbose_json, plain `language` and the
    confidence metrics is_valid() rejects silence with."""
    monkeypatch.setenv("STT_MODEL", "whisper-1")
    t = VoiceTranscriber()
    segment = type("Seg", (), {"no_speech_prob": 0.9, "avg_logprob": -0.4})()
    create = _stub(t, text="thank you", language="en", duration=1.0, segments=[segment])

    result = await t.transcribe(
        io.BytesIO(b"x"), "answer.wav", language="en", keyterms=["Paris"]
    )

    kwargs = create.await_args.kwargs
    assert kwargs["response_format"] == "verbose_json"
    assert kwargs["language"] == "en"
    assert "extra_body" not in kwargs
    assert result.no_speech_prob == pytest.approx(0.9)
    assert not result.is_valid()  # silence, caught by no_speech_prob


async def test_mcq_keyterms_never_leaks_an_open_question_answer():
    """Keyterms bias the recogniser — for an open question that would transcribe
    the correct answer no matter what the player actually said."""
    from app.api.routes.voice import mcq_keyterms

    class Q:
        id = "q1"
        possible_answers = None

    class S:
        language = "en"
        current_question_translation = None

    assert mcq_keyterms(Q(), S()) == []


async def test_mcq_keyterms_prefers_the_translation_the_player_heard():
    """The player answers in the language the options were read out in."""
    from app.api.routes.voice import mcq_keyterms

    class Q:
        id = "q1"
        possible_answers = {"a": "Mexico", "b": "Brazil"}

    class S:
        language = "sk"
        client_capabilities: list[str] = []
        current_question_translation = {
            "question_id": "q1",
            "language": "sk",
            "possible_answers": {"a": "Mexiko", "b": "Brazília"},
        }

    terms = mcq_keyterms(Q(), S())
    assert terms[:2] == ["Mexiko", "Brazília"]
    assert "Mexico" not in terms


async def test_mcq_keyterms_include_the_labels_the_player_says():
    """#185 G: the car test lost a spoken "C" entirely. The recogniser is told
    the words for the labels this client shows — letters for a build that
    predates `option-labels`, 1–4 (or letters for numeric options) after it."""
    from app.api.routes.voice import mcq_keyterms

    class Q:
        id = "q1"
        possible_answers = {"a": "Mars", "b": "Venus", "c": "Jupiter", "d": "Saturn"}

    class Legacy:
        language = "sk"
        client_capabilities: list[str] = []
        current_question_translation = None

    class Labelled(Legacy):
        client_capabilities = ["option-labels"]

    assert mcq_keyterms(Q(), Legacy())[4:] == ["áčko", "béčko", "céčko", "déčko"]
    assert mcq_keyterms(Q(), Labelled())[4:] == ["jedna", "dva", "tri", "štyri"]
