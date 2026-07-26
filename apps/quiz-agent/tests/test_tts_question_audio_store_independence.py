"""Serving already-cached question audio must not depend on the question store.

Why this matters: /question/audio is the hands-free hot path — it is what the
driver waits on between questions. ``QuestionRetriever.get`` goes to
``SyncPgvectorStore.get``, which blocks the FastAPI event-loop thread on a
Postgres round trip, so making it a per-request dependency means a DB blip
turns a question whose text AND audio are already cached into an HTTP 500 in a
moving car.

The subtler half is silent: if the lookup merely returns None, the route would
build a *different* string than the warm-up hashed — cache miss, no options,
no signal. So the spoken text is assembled once where the question is chosen
and cached on the session; these tests pin that the route reads it and never
touches the store.
"""

from unittest.mock import patch

import pytest
from quiz_shared.models.question import Question

from tests.question_audio_harness import (
    RecordingTTS,
    question_audio,
    start_quiz_for,
)

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


def _venus_mcq() -> Question:
    return Question(
        id="q_venus",
        question="Roughly how many Earth days does one Venus day last?",
        type="text_multichoice",
        possible_answers={"a": "10", "b": "100", "c": "240"},
        correct_answer="c",
        topic="Science",
        category="general",
        difficulty="medium",
    )


@pytest.mark.parametrize(
    "outage",
    [
        pytest.param({"side_effect": RuntimeError("connection reset")}, id="db-blip"),
        pytest.param({"return_value": None}, id="row-vanished"),
    ],
)
async def test_question_audio_never_hits_the_store(outage):
    """A store outage must not cost the driver audio that is already assembled."""
    question = _venus_mcq()
    manager, session_id, retriever = await start_quiz_for(question)

    retriever.get.configure_mock(**outage)

    spoken = await question_audio(manager, session_id, retriever, RecordingTTS())

    # Full read-out, byte-identical to what /start warmed — the store outage is
    # invisible because the route never consulted the store.
    assert spoken == manager.get_session(session_id).current_question_speech_text
    assert "A: 10." in spoken and "B: 100." in spoken and "C: 240." in spoken
    retriever.get.assert_not_called()


async def test_legacy_session_degrades_loudly_instead_of_failing():
    """A session with no cached speech text is the only path left to the store.

    Sessions written before the speech text was cached (a deploy mid-quiz)
    still need the row for the option read-out. Losing it must cost the options
    and page Sentry — not 500 the question — the same fail-loud-but-keep-driving
    shape as ``boost_volume``.
    """
    question = _venus_mcq()
    manager, session_id, retriever = await start_quiz_for(question)

    session = manager.get_session(session_id)
    session.current_question_speech_text = None
    manager.update_session(session)
    retriever.get.side_effect = RuntimeError("connection reset")

    with patch("app.api.routes.tts.sentry_sdk.capture_message") as capture:
        spoken = await question_audio(manager, session_id, retriever, RecordingTTS())

    # The question is still spoken; only the options are lost.
    assert spoken == question.question

    capture.assert_called_once()
    message, kwargs = capture.call_args[0][0], capture.call_args[1]
    assert kwargs["level"] == "error"
    assert question.id in message
    assert "options" in message.lower()

    # The options-less build must not be cached, or every later request for
    # this question would inherit a permanently degraded read-out.
    assert manager.get_session(session_id).current_question_speech_text is None
