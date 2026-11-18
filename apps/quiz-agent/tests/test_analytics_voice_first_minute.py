"""#240.9 — the fields the app sends from PR #905 (the voice-first minute).

Why these tests exist: the server drops every property key it does not list,
silently. #240 measures whether the mic opening by itself after the question
helps store players answer, so these keys must be stored from the first beta
build that sends them, or the numbers simply never show up. Old builds that
send none of them must keep being stored as before.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.analytics.recorder import AnalyticsRecorder, ClientEvent  # noqa: E402
from app.analytics.taxonomy import (  # noqa: E402
    CLIENT_EVENTS,
    MAX_STRING_LEN,
    clean_properties,
)
from app.db.models import AnalyticsEvent  # noqa: E402

pytestmark = pytest.mark.asyncio


async def test_answer_captured_keeps_who_opened_the_mic_and_how_soon():
    # The core of #240.9: auto-opened mic vs tap, the delay after the question
    # read-out, whether anything was heard, and a refused mic. The transcript
    # never rides along.
    cleaned = clean_properties(
        CLIENT_EVENTS["answer_captured"],
        {
            "trigger": "auto",
            "mic_open_delay_ms": 600,
            "peak_db": -24,
            "mic_permission": "granted",
            "transcript": "paris",
        },
    )
    assert cleaned == {
        "trigger": "auto",
        "mic_open_delay_ms": 600,
        "peak_db": -24,
        "mic_permission": "granted",
    }


async def test_quiz_abandoned_keeps_how_and_where_the_round_was_left():
    # Store players leave rounds; the reason (end_quiz | end_with_results |
    # error_screen) and the question on screen say where the round loses them.
    cleaned = clean_properties(
        CLIENT_EVENTS["quiz_abandoned"],
        {
            "questions_answered": 3,
            "phase": "askingQuestion",
            "reason": "error_screen",
            "question": 4,
            "error_message": "x",
        },
    )
    assert cleaned == {
        "questions_answered": 3,
        "phase": "askingQuestion",
        "reason": "error_screen",
        "question": 4,
    }


async def test_build_channel_is_kept_on_every_app_event():
    # Store players must never be read next to testers and debug runs, so the
    # channel has to survive on every event the app posts, not just some.
    for name, allowed in CLIENT_EVENTS.items():
        cleaned = clean_properties(allowed, {"build_channel": "testflight"})
        assert cleaned == {"build_channel": "testflight"}, name


async def test_build_channel_is_app_only():
    # Server events have no build: the channel comes from the app's own build.
    from app.analytics.taxonomy import SERVER_EVENTS

    assert all("build_channel" not in keys for keys in SERVER_EVENTS.values())


async def test_new_capture_failure_reasons_pass_like_every_reason():
    # silent (#240.9) and mic_denied (#888) ride on the existing `reason` key;
    # values are not checked one by one, an unknown one is kept as sent and
    # cut to the length limit, exactly as every other enum-like field.
    allowed = CLIENT_EVENTS["voice_capture_failed"]
    for reason in ("silent", "mic_denied"):
        cleaned = clean_properties(allowed, {"reason": reason, "question_id": "q1"})
        assert cleaned == {"reason": reason, "question_id": "q1"}
    long_value = clean_properties(
        CLIENT_EVENTS["answer_captured"], {"trigger": "x" * 500}
    )
    assert long_value == {"trigger": "x" * MAX_STRING_LEN}


async def test_new_and_old_builds_are_both_stored(db_sessionmaker):
    # A #905 build sends the new keys; an older build sends none of them. Both
    # rows land, the new one with its channel and capture fields.
    recorder = AnalyticsRecorder(db_sessionmaker)
    at = datetime(2026, 11, 19, 9, 0, tzinfo=timezone.utc)
    accepted, dropped = await recorder.record_client_batch(
        [
            ClientEvent(
                "answer_captured",
                at,
                "s-new",
                {
                    "question_id": "q1",
                    "trigger": "tap",
                    "mic_open_delay_ms": 0,
                    "peak_db": -60,
                    "mic_permission": "denied",
                    "build_channel": "testflight",
                },
            ),
            ClientEvent("answer_captured", at, "s-old", {"question_id": "q1"}),
        ],
        subject_id="anon-1",
        app_version="1.3",
    )
    assert (accepted, dropped) == (2, 0)
    async with db_sessionmaker() as s:
        rows = {
            r.session_id: r.properties
            for r in (await s.execute(select(AnalyticsEvent))).scalars()
        }
    assert rows["s-new"] == {
        "question_id": "q1",
        "trigger": "tap",
        "mic_open_delay_ms": 0,
        "peak_db": -60,
        "mic_permission": "denied",
        "build_channel": "testflight",
    }
    assert rows["s-old"] == {"question_id": "q1"}
