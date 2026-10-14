"""#204.2: a re-record must not hand the player the same wrong transcript again.

Founder 2026-10-14: the player says "modrá", the app hears "mokrá" and the
player re-records. Re-grading "mokrá" a second time is the one outcome that
makes the retry pointless, so when the new transcript equals one the player
already rejected the server tries another hypothesis (Scribe with the answer as
bias and a new seed, then the OpenAI fallback). A client that never sends the
field (the shipped 1.0 build) must see exactly the old single-call behaviour.
"""

from __future__ import annotations

import io
import json
import os
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402

from app.voice.transcriber import TranscriptionResult, VoiceTranscriber  # noqa: E402
from tests import test_answer_retry_contract as base  # noqa: E402
from tests.test_answer_retry_contract import (  # noqa: E402
    _SID,
    _Q1,
    _Harness,
    _mcq,
    _open,
)

client_for = base.client_for  # the fixture, re-exported for pytest

pytestmark = pytest.mark.asyncio


def _res(text: str, logprob: float = -0.1) -> TranscriptionResult:
    return TranscriptionResult(
        text=text, language="sk", no_speech_prob=0.0, avg_logprob=logprob, duration=1.0
    )


def _transcriber(monkeypatch, first="mokrá", scribe=None, openai=None):
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    t = VoiceTranscriber()
    t.transcribe_with_quiz_context = AsyncMock(return_value=_res(first))
    t._transcribe_scribe = AsyncMock(
        side_effect=scribe if isinstance(scribe, Exception) else None,
        return_value=scribe if not isinstance(scribe, Exception) else None,
    )
    t._transcribe_openai = AsyncMock(return_value=openai)
    return t


async def _submit(h, client, rejected=None):
    data = {} if rejected is None else {"rejected_transcripts": json.dumps(rejected)}
    return await client.post(
        f"/api/v1/voice/submit/{_SID}?question_id={_Q1}&include_audio=false",
        files={"audio": ("answer.wav", b"RIFF", "audio/wav")},
        data=data,
    )


def _graded_text(h) -> str:
    c = h.parser.parse.await_args
    return c.kwargs.get("user_input") or c.args[0]


async def test_rejected_mokra_is_replaced_by_the_second_hypothesis(
    client_for, monkeypatch
):
    """The whole point: the retry must grade "modrá", not "mokrá" again."""
    h = _Harness(_mcq())
    h.transcriber = _transcriber(monkeypatch, scribe=_res("modrá"))
    client = await client_for(h)

    await _submit(h, client, rejected=["Mokrá."])

    assert _graded_text(h) == "modrá"
    kwargs = h.transcriber._transcribe_scribe.await_args.kwargs
    assert kwargs["seed"] is not None  # a different decoding, not a replay
    assert "Jupiter" in kwargs["keyterms"]  # same options as the first pass
    h.transcriber._transcribe_openai.assert_not_awaited()


async def test_open_question_retry_never_carries_the_expected_answer(
    client_for, monkeypatch
):
    """Otherwise mumble -> reject -> retry would bias the recogniser toward the
    answer and get it accepted without the player knowing it."""
    h = _Harness(_open())  # correct answer: "curling"
    h.transcriber = _transcriber(
        monkeypatch, first="kurling", scribe=_res("kurling"), openai=_res("kurling")
    )
    client = await client_for(h)

    await _submit(h, client, rejected=["kurling"])

    for call in (h.transcriber._transcribe_scribe, h.transcriber._transcribe_openai):
        kw = call.await_args.kwargs
        assert not kw["keyterms"]
        assert "curling" not in json.dumps(kw, default=str).lower()
    assert "prompt" in h.transcriber._transcribe_openai.await_args.kwargs


async def test_falls_through_to_openai_then_keeps_the_original(client_for, monkeypatch):
    h = _Harness(_mcq())
    h.transcriber = _transcriber(
        monkeypatch, scribe=_res("mokrá"), openai=_res("Mokrá")
    )
    client = await client_for(h)

    await _submit(h, client, rejected=["mokrá"])

    # Both extra hypotheses repeat the rejected words: nothing better exists,
    # so the original goes through (and the extra calls are capped at two).
    assert _graded_text(h) == "mokrá"
    assert h.transcriber._transcribe_scribe.await_count == 1
    assert h.transcriber._transcribe_openai.await_count == 1


async def test_a_failing_provider_does_not_cost_the_answer(client_for, monkeypatch):
    h = _Harness(_mcq())
    h.transcriber = _transcriber(
        monkeypatch, scribe=RuntimeError("quota"), openai=_res("modrá")
    )
    client = await client_for(h)

    await _submit(h, client, rejected=["mokrá"])

    assert _graded_text(h) == "modrá"


async def test_no_field_means_exactly_one_recognition(client_for, monkeypatch):
    """1.0 builds never send the field: no extra paid STT call, same transcript."""
    h = _Harness(_mcq())
    h.transcriber = _transcriber(monkeypatch, scribe=_res("modrá"))
    client = await client_for(h)

    await _submit(h, client, rejected=None)

    assert _graded_text(h) == "mokrá"
    h.transcriber._transcribe_scribe.assert_not_awaited()
    h.transcriber._transcribe_openai.assert_not_awaited()


async def test_a_transcript_that_was_not_rejected_costs_no_extra_call(
    client_for, monkeypatch
):
    h = _Harness(_mcq())
    h.transcriber = _transcriber(monkeypatch, first="modrá", scribe=_res("x"))
    client = await client_for(h)

    await _submit(h, client, rejected=["mokrá"])

    assert _graded_text(h) == "modrá"
    h.transcriber._transcribe_scribe.assert_not_awaited()


async def test_server_flag_off_ignores_the_field(client_for, monkeypatch):
    h = _Harness(_mcq())
    h.transcriber = _transcriber(monkeypatch, scribe=_res("modrá"))
    monkeypatch.setenv("STT_RETRY_AVOID_REJECTED", "false")
    client = await client_for(h)

    await _submit(h, client, rejected=["mokrá"])

    assert _graded_text(h) == "mokrá"


@pytest.mark.parametrize(
    "bad",
    [["a"] * 6, ["x" * 201], [1, 2], {"a": 1}],
)
async def test_malformed_field_is_a_400_before_any_stt(client_for, monkeypatch, bad):
    h = _Harness(_mcq())
    h.transcriber = _transcriber(monkeypatch)
    client = await client_for(h)

    resp = await _submit(h, client, rejected=bad)

    assert resp.status_code == 400
    h.transcriber.transcribe_with_quiz_context.assert_not_awaited()


async def test_retry_logs_never_contain_the_player_words(monkeypatch, caplog):
    t = _transcriber(monkeypatch, scribe=_res("modrá"))
    caplog.set_level("INFO")

    result, calls = await t.transcribe_avoiding_rejected(
        io.BytesIO(b"x"),
        "a.wav",
        first=_res("mokrá"),
        rejected={"mokrá"},
        language="sk",
        keyterms=["modrá"],
    )

    assert (result.text, calls) == ("modrá", 1)
    assert "mokr" not in caplog.text and "modr" not in caplog.text
