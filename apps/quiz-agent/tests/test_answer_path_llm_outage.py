"""#193 (193.11): an LLM outage must not hang the player's answer, nor 500 it.

Before: the intent classifier and the judge each used the factory default of
30 s per attempt with the SDK's 2 retries, so a slow or down provider held a
submit for 30–90 s and then answered 500 — after iOS had already given up at
30 s. Now each call is capped and a failure becomes the existing "say it again"
400 that shipped builds already turn into a re-ask.

What must hold:
- the failure is fast (bounded well inside iOS's 30 s budget);
- nothing is graded, scored, recorded or charged for an answer nobody judged;
- answers a deterministic path can settle (MCQ) are still graded normally;
- a call that succeeds sends exactly the request it sent before.
"""

from __future__ import annotations

import asyncio
import os
import time
from unittest.mock import MagicMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import httpx
import openai
import pytest
from app import hot_path_llm
from app.evaluation.evaluator import AnswerEvaluator
from app.input.parser import InputParser
from app.quiz.errors import JudgeUnavailable

from tests import test_answer_retry_contract as contract
from tests.test_answer_retry_contract import (
    _CODES,
    _assert_untouched,
    _Harness,
    _mcq,
    _open,
)

client_for = contract.client_for  # the #185 route harness's client fixture

pytestmark = pytest.mark.asyncio

_REQUEST = httpx.Request("POST", "https://llm.test/v1/chat/completions")


async def _provider_down(**kwargs):
    raise openai.APIConnectionError(request=_REQUEST)


async def _provider_timeout(**kwargs):
    raise openai.APITimeoutError(request=_REQUEST)


def _reply(text: str):
    response = MagicMock()
    response.choices = [MagicMock()]
    response.choices[0].message.content = text
    return response


@pytest.fixture(autouse=True)
def _fresh_incident(monkeypatch):
    """Each test starts outside any reported incident."""
    monkeypatch.setattr(hot_path_llm, "_last_reported_at", None)


# ── The bound ────────────────────────────────────────────────────────────────


def test_the_answer_path_client_cannot_outlast_the_app():
    """The SDK defaults (2 retries) on the factory's 30 s timeout are what let
    one call run 90 s. Pin the bound so it cannot drift back."""
    llm = hot_path_llm.client()

    assert llm.max_retries == 1
    assert llm.timeout.read == 6.0
    assert llm.timeout.connect == 2.0
    # Two capped calls (classifier + judge) still fit iOS's 30 s submit budget
    # with room for upload, transcription and the feedback TTS.
    assert 2 * hot_path_llm.CALL_BUDGET_S <= 20


async def test_a_hanging_provider_fails_within_the_call_budget(monkeypatch):
    """The per-call cap also covers what the SDK timeout does not (a
    Retry-After sleep of up to 60 s)."""
    monkeypatch.setattr(hot_path_llm, "CALL_BUDGET_S", 0.05)
    evaluator = AnswerEvaluator()

    async def _hang(**kwargs):
        await asyncio.sleep(30)

    evaluator.client.chat.completions.create = _hang
    started = time.monotonic()

    with pytest.raises(JudgeUnavailable) as raised:
        await evaluator.evaluate("the curler", _open())

    assert time.monotonic() - started < 1.0
    assert raised.value.stage == "evaluate"


@pytest.mark.parametrize("failure", [_provider_down, _provider_timeout])
async def test_provider_errors_become_judge_unavailable_not_a_crash(failure):
    parser = InputParser()
    parser.client.chat.completions.create = failure

    with pytest.raises(JudgeUnavailable) as raised:
        await parser.parse(
            "I think it is the one with the brooms", "Which sport?", "asking"
        )

    assert raised.value.stage == "parse"


async def test_sentry_hears_once_per_incident_and_never_the_answer(monkeypatch):
    """Every player answering during an outage fails the same way; one event
    is the signal, a thousand is noise. The answer must not leave the server."""
    captured: list[str] = []
    active = MagicMock()
    active.is_active.return_value = True
    monkeypatch.setattr(hot_path_llm.sentry_sdk, "get_client", lambda: active)
    monkeypatch.setattr(
        hot_path_llm.sentry_sdk,
        "capture_message",
        lambda message, **kw: captured.append(message),
    )
    evaluator = AnswerEvaluator()
    evaluator.client.chat.completions.create = _provider_down

    for _ in range(3):
        with pytest.raises(JudgeUnavailable):
            await evaluator.evaluate("secret spoken answer", _open())

    assert len(captured) == 1
    assert "secret spoken answer" not in captured[0]


# ── The happy path is unchanged ──────────────────────────────────────────────


async def test_a_successful_call_sends_the_same_request_and_verdict():
    """Quality must not change: the guard adds no request parameters and the
    verdict mapping is untouched."""
    evaluator = AnswerEvaluator()
    sent: list[dict] = []

    async def _create(**kwargs):
        sent.append(kwargs)
        return _reply("partially_correct")

    evaluator.client.chat.completions.create = _create

    result = await evaluator.evaluate("the ice one with stones", _open())

    assert result == ("partially_correct", 0.5)
    assert set(sent[0]) == {"model", "temperature", "messages"}


# ── Through the real routes ──────────────────────────────────────────────────


@pytest.mark.parametrize("route", ["text", "voice"])
async def test_judge_down_asks_again_and_grades_nothing(client_for, route):
    """The coded 400 shipped builds re-ask on: spoken "try again", then Again /
    Skip. No verdict, no point, no quota for an answer nobody judged."""
    h = _Harness(_open(), capabilities=_CODES)
    h.flow.answer_evaluator.client.chat.completions.create = _provider_timeout
    client = await client_for(h)

    resp = await getattr(h, route)(client, "the stone one")

    assert resp.status_code == 400
    detail = resp.json()["detail"]
    assert detail["code"] == "no_answer"
    assert detail["reason"] == "judge_unavailable"
    _assert_untouched(h)


@pytest.mark.parametrize("route", ["text", "voice"])
async def test_legacy_build_gets_the_plain_retry_400_not_a_500(client_for, route):
    h = _Harness(_open())
    h.flow.answer_evaluator.client.chat.completions.create = _provider_down
    client = await client_for(h)

    resp = await getattr(h, route)(client, "the stone one")

    assert resp.status_code == 400
    assert isinstance(resp.json()["detail"], str)
    _assert_untouched(h)


async def test_classifier_down_asks_again_too(client_for):
    """A longer utterance needs the classifier first; its outage ends the
    submit the same way, before the judge is even tried."""
    h = _Harness(_open(), capabilities=_CODES)
    h.flow.input_parser = InputParser()
    h.flow.input_parser.client.chat.completions.create = _provider_down
    client = await client_for(h)

    resp = await h.voice(client, "I am pretty sure that it is curling")

    assert resp.status_code == 400
    assert resp.json()["detail"]["reason"] == "judge_unavailable"
    _assert_untouched(h)


async def test_mcq_answers_are_still_graded_during_an_outage(client_for):
    """Option matching is deterministic and never needed the LLM — an outage
    must not take it down with the judge."""
    h = _Harness(_mcq(), capabilities=_CODES)
    h.flow.answer_evaluator.client.chat.completions.create = _provider_down
    client = await client_for(h)

    resp = await h.voice(client, "céčko")

    assert resp.status_code == 200
    assert resp.json()["evaluation"]["result"] == "correct"


async def test_a_re_grade_during_an_outage_keeps_the_verdict_given(client_for):
    """Editing a transcript re-grades (#133); if the judge is down for the edit,
    the answer the player already got a verdict for must stand."""
    h = _Harness(_open(), capabilities=_CODES)
    evaluator = h.flow.answer_evaluator

    async def _correct(**kwargs):
        return _reply("correct")

    evaluator.client.chat.completions.create = _correct
    client = await client_for(h)
    assert (await h.voice(client, "the stone one")).status_code == 200
    graded = h.manager.stored.last_evaluation
    score = h.manager.stored.participants[0].score

    evaluator.client.chat.completions.create = _provider_down
    resp = await h.text(client, "the broom one")

    assert resp.status_code == 400
    assert h.manager.stored.last_evaluation == graded
    assert h.manager.stored.participants[0].score == score
