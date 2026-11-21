"""The free tier split (founder experiment, 2026-11-21): 150 questions a month,
at most 30 of them answered by voice.

A voice answer is the only part of an answer with a real per-use cost (the
transcription), so the free tier can be generous for typed and tapped play
while voice stays the thing worth paying for. These tests pin the rules that
make the experiment honest: only a usable transcription costs a voice answer,
one answer never costs two, typing and tapping never cost one, paying players
are never refused, and a refused player can still type or tap — while shipped
builds, which cannot explain the refusal, are not refused unless switched on.
"""

from __future__ import annotations

from datetime import timedelta
from unittest.mock import AsyncMock

import pytest

from app import app_switches
from app.analytics.taxonomy import SERVER_EVENTS, clean_properties
from app.api.deps import UsageResponse
from app.db.base import utcnow
from app.db.models import (
    AnonymousIdentity,
    CreditLedger,
    DailyUsage,
    Product,
    Subscription,
)
from app.usage.account_merge import merge_anonymous_identity
from app.usage.tracker import UsageTracker, _month_start
from tests import test_answer_retry_contract as contract
from tests.test_answer_retry_contract import _SUBJECT, _Harness, _open

client_for = contract.client_for

pytestmark = pytest.mark.asyncio

NEW_BUILD = ["answer-codes", "option-labels", "voice-allowance"]
OLD_BUILD = ["answer-codes", "option-labels"]  # what builds up to TF 90 send


@pytest.fixture(autouse=True)
def _rc_allowed_environment(monkeypatch):
    monkeypatch.setenv("RC_ALLOWED_ENVIRONMENT", "PRODUCTION")
    app_switches.reset_cache()
    yield
    app_switches.reset_cache()


class _Events:
    def __init__(self):
        self.rows: list[tuple[str, dict]] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        self.rows.append((name, clean_properties(SERVER_EVENTS[name], properties)))

    def named(self, name):
        return [p for n, p in self.rows if n == name]


async def _seed(db, *, questions=0, voice=0, usage_date=None):
    async with db() as s:
        s.add(
            DailyUsage(
                subject_id=_SUBJECT,
                usage_date=usage_date or _month_start(),
                questions_count=questions,
                voice_answers=voice,
            )
        )
        await s.commit()


def _harness(db, capabilities, *, voice_limit=30):
    h = _Harness(_open(), capabilities=capabilities)
    h.tracker = UsageTracker(db, voice_monthly_limit=voice_limit)
    h.flow.usage_tracker = h.tracker
    h.events = _Events()
    h.flow.analytics = h.events
    return h


async def _voice_used(h) -> int:
    return (await h.tracker.get_usage(_SUBJECT))["voice_answers_used"]


# ── Limits ───────────────────────────────────────────────────────────────────


async def test_free_question_limit_is_150_and_voice_limit_30(db_sessionmaker):
    """The experiment's numbers, at the single place they are defined."""
    tracker = UsageTracker(db_sessionmaker)
    await _seed(db_sessionmaker, questions=149, voice=30)

    assert (await tracker.check_limit(_SUBJECT))[:2] == (True, 1)
    await tracker.record_question(_SUBJECT)
    assert (await tracker.check_limit(_SUBJECT))[0] is False
    voice = await tracker.check_voice_answer(_SUBJECT, "voice_answer:s:q")
    assert (voice.allowed, voice.used, voice.limit) == (False, 30, 30)


async def test_usage_keeps_the_old_fields_and_adds_the_voice_ones(db_sessionmaker):
    """Live builds decode ``/usage/me`` with these exact keys; the voice fields
    only ride next to them."""
    await _seed(db_sessionmaker, questions=40, voice=12)
    usage = await UsageTracker(db_sessionmaker).get_usage(_SUBJECT)

    assert {
        k: usage[k] for k in ("questions_used", "questions_limit", "remaining")
    } == {
        "questions_used": 40,
        "questions_limit": 150,
        "remaining": 110,
    }
    assert {"user_id", "is_premium", "resets_at", "subscription_status"} <= set(usage)
    assert (usage["credit_balance"], usage["plan"]) == (0, "free")
    assert (
        usage["voice_answers_used"],
        usage["voice_answers_limit"],
        usage["voice_answers_remaining"],
    ) == (12, 30, 18)
    UsageResponse.model_validate(usage)  # the declared response shape


async def test_monthly_reset_resets_questions_and_voice(db_sessionmaker):
    """Both counters share one window: last month's spend is gone on the 1st."""
    await _seed(
        db_sessionmaker,
        questions=150,
        voice=30,
        usage_date=_month_start() - timedelta(days=1),
    )
    tracker = UsageTracker(db_sessionmaker)

    assert (await tracker.check_limit(_SUBJECT))[0] is True
    assert (await tracker.check_voice_answer(_SUBJECT, "k")).allowed is True
    usage = await tracker.get_usage(_SUBJECT)
    assert (usage["questions_used"], usage["voice_answers_used"]) == (0, 0)


async def test_paying_players_have_no_voice_limit(db_sessionmaker):
    """Trubbo Plus and pack credits are paid: voice is what they paid for."""
    await _seed(db_sessionmaker, voice=500)
    tracker = UsageTracker(db_sessionmaker)
    async with db_sessionmaker() as s:
        s.add(Product(product_id="plus", kind="subscription", tier="unlimited"))
        s.add(
            Subscription(
                account_id=_SUBJECT,
                product_id="plus",
                status="active",
                expires_at=utcnow() + timedelta(days=10),
                rc_original_txn_id="t1",
                last_event_ts_ms=1,
                environment="PRODUCTION",
            )
        )
        await s.commit()
    check = await tracker.check_voice_answer(_SUBJECT, "k")
    assert (check.allowed, check.limit) == (True, None)
    assert (await tracker.get_usage(_SUBJECT))["voice_answers_limit"] is None

    async with db_sessionmaker() as s:  # lapsed, but holds pack credits
        sub = await s.get(Subscription, _SUBJECT)
        sub.expires_at = utcnow() - timedelta(days=1)
        s.add(CreditLedger(account_id=_SUBJECT, delta=10, kind="grant", reason="t"))
        await s.commit()
    assert (await tracker.check_voice_answer(_SUBJECT, "k")).allowed is True


async def test_signing_in_does_not_hand_out_fresh_voice_answers(db_sessionmaker):
    """Sign-in folds the anonymous device's usage into the account by SUM, so
    signing out and back in cannot reset the voice allowance either."""
    async with db_sessionmaker() as s:
        s.add(AnonymousIdentity(anon_id="anon_voice"))
        for subject, voice in (("anon_voice", 20), (_SUBJECT, 7)):
            s.add(
                DailyUsage(
                    subject_id=subject, usage_date=_month_start(), voice_answers=voice
                )
            )
        await s.commit()
    async with db_sessionmaker() as s:
        await merge_anonymous_identity(s, "anon_voice", _SUBJECT)
        await s.commit()

    usage = await UsageTracker(db_sessionmaker).get_usage(_SUBJECT)
    assert usage["voice_answers_used"] == 27


# ── Charging on /voice/submit ────────────────────────────────────────────────


async def test_voice_answer_charges_voice_and_typed_does_not(
    client_for, db_sessionmaker
):
    h = _harness(db_sessionmaker, NEW_BUILD)
    c = await client_for(h)

    assert (await h.text(c, "curling")).status_code == 200
    assert await _voice_used(h) == 0  # typed: no transcription, no cost
    assert (await h.voice(c, "Jupiter", question_id="q_next")).status_code == 200
    assert await _voice_used(h) == 1


async def test_failed_transcription_does_not_charge(client_for, db_sessionmaker):
    """Nothing usable heard, or the recogniser down: the player got nothing."""
    h = _harness(db_sessionmaker, NEW_BUILD)
    c = await client_for(h)

    assert (await h.voice(c, "")).status_code == 400  # no speech
    h.transcriber.transcribe_with_quiz_context = AsyncMock(
        side_effect=ConnectionError("openai down")
    )
    assert (await h.voice(c, "curling")).status_code >= 500
    assert await _voice_used(h) == 0


async def test_a_retried_answer_is_charged_once(client_for, db_sessionmaker):
    """ "Say it again", the resend after a lost response and a re-grade are all
    the same answer to the same question."""
    h = _harness(db_sessionmaker, NEW_BUILD)
    c = await client_for(h)

    assert (await h.voice(c, "hmm what")).status_code == 400  # heard, no answer
    assert (await h.voice(c, "curling")).status_code == 200  # said again
    assert (await h.voice(c, "curling")).status_code == 200  # resend: replayed
    assert await _voice_used(h) == 1


async def test_past_the_voice_limit_voice_is_refused_and_typing_works(
    client_for, db_sessionmaker
):
    """The 31st voice answer of a free player with questions left: refused
    before the transcription is paid for, in a shape the new build turns into
    "type or tap instead" — and typing that same question still works."""
    await _seed(db_sessionmaker, questions=40, voice=30)
    h = _harness(db_sessionmaker, NEW_BUILD)
    h.transcriber.transcribe_with_quiz_context = AsyncMock()
    c = await client_for(h)

    resp = await h.voice(c, "curling")

    assert resp.status_code == 429
    detail = resp.json()["detail"]
    assert detail["code"] == "voice_limit_reached"
    assert (detail["voice_answers_used"], detail["voice_answers_limit"]) == (30, 30)
    # A shipped build must not read it as the quota wall (round over, paywall).
    assert not {"error", "questions_used", "upgrade_available"} & set(detail)
    h.transcriber.transcribe_with_quiz_context.assert_not_awaited()
    assert h.events.named("voice_quota_hit") == [
        {"voice_answers_used": 30, "voice_answers_limit": 30, "enforced": True}
    ]
    assert h.events.named("transcription_failed")[-1]["reason"] == "voice_limit"

    typed = await h.text(c, "curling")
    assert typed.status_code == 200
    assert typed.json()["evaluation"]["result"] == "correct"


async def test_the_answer_charged_last_is_not_refused_on_retry(
    client_for, db_sessionmaker
):
    """The 30th voice answer that met a 503 is resent: it is already paid for,
    so the full allowance must not turn the retry into a refusal."""
    h = _harness(db_sessionmaker, NEW_BUILD, voice_limit=1)
    c = await client_for(h)

    assert (await h.voice(c, "hmm what")).status_code == 400  # charged: 1 of 1
    assert (await h.voice(c, "curling")).status_code == 200
    assert await _voice_used(h) == 1


async def test_shipped_builds_are_counted_not_refused_unless_switched_on(
    client_for, db_sessionmaker
):
    """Builds up to TF 90 cannot say why voice stopped, so by default they keep
    voice (and the event shows how often they would have been refused). The
    switch turns on the plain 429 their "Too many requests" screen handles."""
    await _seed(db_sessionmaker, voice=30)
    h = _harness(db_sessionmaker, OLD_BUILD)
    h.app.state.auth_sessionmaker = db_sessionmaker
    c = await client_for(h)

    assert (await h.voice(c, "curling")).status_code == 200
    assert await _voice_used(h) == 31
    assert h.events.named("voice_quota_hit")[0]["enforced"] is False

    await app_switches.write(db_sessionmaker, {"voice_limit_old_builds": True}, [])
    resp = await h.voice(c, "jupiter", question_id="q_next")
    assert resp.status_code == 429
    assert resp.json()["detail"]["code"] == "voice_limit_reached"


async def test_family_round_is_never_refused_mid_round(client_for, db_sessionmaker):
    """#236: a round with kids is never cut off mid-round; voice is counted."""
    await _seed(db_sessionmaker, voice=30)
    h = _harness(db_sessionmaker, NEW_BUILD)
    h.manager.stored.age_band = "kids_7_9"
    c = await client_for(h)

    assert (await h.voice(c, "curling")).status_code == 200
    assert await _voice_used(h) == 31
