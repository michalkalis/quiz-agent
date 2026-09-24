"""Batch STT on Scribe v2 with an OpenAI fallback (#184 track C).

Answers are recorded in a moving car: whisper-1 had no per-word confidence, so
road noise and passenger speech captured after the answer were graded as part
of it, and a quota outage on ElevenLabs must never cost the player their turn.
These tests pin the guarantees that follow from that — the trailing
low-confidence run is identified (and cut only when the #185 setting enables
it, never the whole transcript), and every Scribe failure mode falls through to
OpenAI — plus the keyterm hygiene that keeps a long MCQ option from 422-ing the
call, and the two rollback levers (`STT_PROVIDER=openai`, fallback model
`whisper-1`).
"""

from __future__ import annotations

import io
from unittest.mock import AsyncMock

import httpx
import pytest
from httpx import MockTransport, Response

from app.voice.scribe import ScribeUnavailable, sanitize_keyterms
from app.voice.transcriber import VoiceTranscriber

pytestmark = pytest.mark.asyncio


def _words(*pairs: tuple[str, float]) -> list[dict]:
    out: list[dict] = []
    for text, logprob in pairs:
        if out:
            out.append({"text": " ", "type": "spacing", "logprob": 0.0})
        out.append({"text": text, "type": "word", "logprob": logprob})
    return out


def _scribe_payload(
    words: list[dict], *, text: str = "", duration: float = 2.5
) -> dict:
    return {
        "language_code": "sk",
        "language_probability": 0.98,
        "text": text or " ".join(w["text"] for w in words if w["type"] == "word"),
        "words": words,
        "audio_duration_secs": duration,
    }


def _mock_scribe(monkeypatch, *, status: int = 200, payload: dict | None = None):
    """Route every httpx.AsyncClient at a fake ElevenLabs STT; returns the calls."""
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> Response:
        calls.append(request)
        if status != 200:
            return Response(status, json={"detail": "quota exhausted"})
        return Response(200, json=payload or _scribe_payload(_words(("Paris", -0.1))))

    transport = MockTransport(handler)
    real_init = httpx.AsyncClient.__init__

    def patched_init(self, *args, **kwargs):
        kwargs["transport"] = transport
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.AsyncClient, "__init__", patched_init)
    return calls


def _openai_stub(transcriber: VoiceTranscriber, **response_attrs) -> AsyncMock:
    """Replace the OpenAI client on an instance so no network call is made."""
    create = AsyncMock(return_value=type("Resp", (), response_attrs)())
    transcriber.client = type(
        "C",
        (),
        {
            "audio": type(
                "A", (), {"transcriptions": type("T", (), {"create": create})()}
            )()
        },
    )()
    return create


@pytest.fixture(autouse=True)
def openai_key(monkeypatch):
    """VoiceTranscriber builds an OpenAI client eagerly; no call is ever made."""
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LLM_GATEWAY", "direct")


@pytest.fixture
def key(monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "fake-key")


async def test_scribe_success_trims_trailing_noise_when_enabled(
    monkeypatch, key, caplog
):
    """With the #185 setting on, the trailing low-confidence run is cut as road
    noise — the #184 behaviour, kept behind the lever for once it is calibrated."""
    monkeypatch.setenv("STT_TRIM_TRAILING_LOW_CONFIDENCE", "true")
    payload = _scribe_payload(
        _words(("Paríž", -0.05), ("hmm", -2.4), ("čo", -3.1)), duration=3.0
    )
    _mock_scribe(monkeypatch, payload=payload)

    t = VoiceTranscriber()
    with caplog.at_level("INFO"):
        result = await t.transcribe(io.BytesIO(b"RIFFfake"), "answer.wav")

    assert result.text == "Paríž"
    assert result.language == "sk"
    assert result.duration == 3.0
    assert result.avg_logprob == pytest.approx(-0.05)
    assert result.is_valid()
    assert "provider=scribe" in caplog.text


async def test_trailing_trim_is_off_by_default_and_logs_what_it_would_cut(
    monkeypatch, key, caplog
):
    """#185 E: the -1.0 cutoff was never calibrated, and a foreign answer word
    ("curling" in a Slovak quiz) scores low confidence — so by default nothing is
    cut. The would-be cut is logged with every word's logprob (calibration
    data), and confidence is still measured on the answer run, so the
    low-confidence gate rejects exactly what it rejected with trimming on."""
    payload = _scribe_payload(_words(("Hrali", -0.1), ("curling", -1.8)), duration=2.0)
    _mock_scribe(monkeypatch, payload=payload)

    with caplog.at_level("INFO"):
        result = await VoiceTranscriber().transcribe(io.BytesIO(b"x"), "answer.wav")

    assert result.text == "Hrali curling"  # the answer word survives
    assert result.avg_logprob == pytest.approx(-0.1)
    assert result.is_valid()
    assert "would have trimmed 1 word(s) 'curling'" in caplog.text
    assert "('curling', -1.8)" in caplog.text


async def test_trimming_never_empties_the_transcript(monkeypatch, key):
    """If every word is low-confidence the audio was bad as a whole — that has to
    stay visible as a low avg_logprob rejection, not become 'empty transcription'."""
    payload = _scribe_payload(_words(("brm", -2.2), ("šššš", -3.0)))
    _mock_scribe(monkeypatch, payload=payload)

    result = await VoiceTranscriber().transcribe(io.BytesIO(b"x"), "answer.wav")

    assert result.text == "brm šššš"
    assert not result.is_valid()
    assert result.get_rejection_reason().startswith("low_confidence")


async def test_scribe_quota_error_falls_back_to_openai(monkeypatch, key):
    """A quota outage on the shared ElevenLabs key must not cost the player a turn."""
    _mock_scribe(monkeypatch, status=402)

    t = VoiceTranscriber()
    create = _openai_stub(t, text="Paris ")

    result = await t.transcribe(io.BytesIO(b"x"), "answer.wav", language="sk")

    assert result.text == "Paris"
    kwargs = create.await_args.kwargs
    assert kwargs["model"] == "gpt-transcribe"
    assert kwargs["response_format"] == "json"
    assert kwargs["language"] == "sk"


async def test_missing_api_key_skips_the_http_call(monkeypatch):
    """No key configured is a config state, not an outage — don't pay a round trip."""
    monkeypatch.delenv("ELEVENLABS_API_KEY", raising=False)
    calls = _mock_scribe(monkeypatch)

    t = VoiceTranscriber()
    _openai_stub(t, text="Paris")

    result = await t.transcribe(io.BytesIO(b"x"), "answer.wav")

    assert result.text == "Paris"
    assert calls == []


async def test_keyterm_sanitising_drops_what_elevenlabs_rejects():
    """One malformed MCQ option must not 422 the whole transcription."""
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


async def test_stt_provider_openai_skips_scribe(monkeypatch, key):
    """`STT_PROVIDER=openai` is the rollback lever — it must bypass Scribe entirely."""
    monkeypatch.setenv("STT_PROVIDER", "openai")
    calls = _mock_scribe(monkeypatch)

    t = VoiceTranscriber()
    _openai_stub(t, text="Paris")

    await t.transcribe(io.BytesIO(b"x"), "answer.wav")

    assert calls == []


async def test_whisper_fallback_keeps_segment_metrics(monkeypatch, key):
    """Full rollback to whisper-1 must restore verbose_json + the confidence
    metrics is_valid() rejects silence with."""
    monkeypatch.setenv("STT_PROVIDER", "openai")
    monkeypatch.setenv("STT_FALLBACK_MODEL", "whisper-1")

    t = VoiceTranscriber()
    segment = type("Seg", (), {"no_speech_prob": 0.9, "avg_logprob": -0.4})()
    create = _openai_stub(
        t, text="thank you", language="en", duration=1.0, segments=[segment]
    )

    result = await t.transcribe(io.BytesIO(b"x"), "answer.wav")

    assert create.await_args.kwargs["response_format"] == "verbose_json"
    assert result.no_speech_prob == pytest.approx(0.9)
    assert not result.is_valid()  # silence, caught by no_speech_prob


async def test_both_providers_failing_raises(monkeypatch, key):
    """When nothing can transcribe, the route must see the existing RuntimeError."""
    _mock_scribe(monkeypatch, status=500)

    t = VoiceTranscriber()
    t.client = type(
        "C",
        (),
        {
            "audio": type(
                "A",
                (),
                {
                    "transcriptions": type(
                        "T", (), {"create": AsyncMock(side_effect=RuntimeError("boom"))}
                    )()
                },
            )()
        },
    )()

    with pytest.raises(RuntimeError, match="Transcription failed"):
        await t.transcribe(io.BytesIO(b"x"), "answer.wav")


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


async def test_scribe_unavailable_is_typed():
    """The fallback branch keys off one exception type, not string matching."""
    assert issubclass(ScribeUnavailable, RuntimeError)
