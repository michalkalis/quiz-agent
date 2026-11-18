"""Why voice answers are turned away (#240 — app quality from idle subscription
capacity, measurement).

Store players had most voice answers rejected, yet every ``transcription_failed``
row said "no_speech", so nobody could tell a silent mic from a too-short word,
a recogniser outage or a daily cap. Each rejection must record its real reason
and the transcript's length (a count, never the words), and the analytics
allowlist must keep both so they reach the table.
"""

from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from app.analytics.taxonomy import SERVER_EVENTS, clean_properties
from app.api import deps
from app.usage.caps import UsageCaps

from tests import test_answer_retry_contract as contract
from tests.test_answer_retry_contract import _Harness, _open

client_for = contract.client_for

pytestmark = pytest.mark.asyncio


class _Events:
    """Stand-in recorder; stores what the real one would keep."""

    def __init__(self):
        self.rows: list[dict] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        if name == "transcription_failed":
            self.rows.append(clean_properties(SERVER_EVENTS[name], properties))


def _watched(h: _Harness) -> _Events:
    events = _Events()
    h.flow.analytics = events
    return events


@pytest.mark.parametrize(
    "transcript, reason",
    [
        ("", "empty_transcript"),  # nothing recognised: silent or muted mic
        ("x", "too_short"),  # a fragment, not an answer
        ("Thank you.", "hallucination"),  # the recogniser's filler for silence
        ("hmm what", "no_answer"),  # speech, but no answer in it
    ],
)
async def test_a_rejected_voice_answer_records_why_and_how_long(
    client_for, transcript, reason
):
    h = _Harness(_open())
    events = _watched(h)
    c = await client_for(h)

    resp = await h.voice(c, transcript)

    assert resp.status_code == 400
    assert events.rows == [
        {
            "reason": reason,
            "question_id": "q_mcq",
            "transcript_chars": len(transcript.strip()),
        }
    ]


async def test_a_recogniser_failure_is_not_counted_as_silence(client_for):
    h = _Harness(_open())
    events = _watched(h)
    h.transcriber.transcribe_with_quiz_context = AsyncMock(
        side_effect=ConnectionError("openai down")
    )
    c = await client_for(h)

    resp = await h.voice(c, "")

    assert resp.status_code >= 500
    assert events.rows == [{"reason": "stt_error", "question_id": "q_mcq"}]


async def test_a_daily_cap_refusal_is_recorded_as_such(
    client_for, db_sessionmaker, monkeypatch
):
    monkeypatch.setenv("DAILY_CAP_ANSWER_ATTEMPTS", "1")
    h = _Harness(_open())
    caps = UsageCaps(db_sessionmaker)
    h.app.dependency_overrides[deps.get_usage_caps] = lambda: caps
    events = _watched(h)
    c = await client_for(h)

    assert (await h.voice(c, "hmm what")).status_code == 400
    assert (await h.voice(c, "curling")).status_code == 429

    assert [row["reason"] for row in events.rows] == ["no_answer", "daily_cap"]
    assert "transcript_chars" not in events.rows[1]  # nothing was transcribed


async def test_an_accepted_answer_records_no_rejection(client_for):
    h = _Harness(_open())
    events = _watched(h)
    c = await client_for(h)

    assert (await h.voice(c, "curling")).status_code == 200
    assert events.rows == []
