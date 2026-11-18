"""Per-user daily cost caps (#207 — production readiness, task 207.13).

Why they exist: an answer nobody could hear, a re-submit of a graded question,
a realtime STT token and an entitlement sync cost the caller nothing and cost
us provider credit (ElevenLabs Starter: 30k credits a month, shared by every
player). One account, or one leaked attested identity, looping any of them
could drain that balance for everyone. What must hold:

- over a cap the request is refused BEFORE the paid call;
- the refusal is a plain 429 that shipped iOS builds do not read as the quota
  429 (that one opens the paywall, and paying cannot lift an abuse cap);
- a real player's day never reaches a cap, the count is per subject and per
  UTC day, and a counter that cannot be written never blocks an answer.
"""

from __future__ import annotations

import io
import struct
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.api import deps
from app.api.routes import entitlements as entitlements_routes
from app.api.routes import misc as misc_routes
from app.auth.identity import AuthSubject
from app.db.models import UsageCounter
from app.rate_limit import limiter
from app.usage import rc_service
from app.config import Settings
from app.usage.caps import (
    STT_SECONDS,
    UNKNOWN_CLIP_SECONDS,
    DailyCapExceeded,
    UsageCaps,
    answer_attempts,
    recording_seconds,
)

from tests import test_answer_retry_contract as contract
from tests.test_answer_retry_contract import _Harness, _open
from tests.test_misc_elevenlabs_quota_gate import _mock_elevenlabs

client_for = contract.client_for  # the #185 route harness's client fixture

pytestmark = pytest.mark.asyncio

_T0 = datetime(2026, 10, 16, 23, 0, tzinfo=timezone.utc)


def _wav(seconds: float, *, rate: int = 16000, filler: int = 0) -> bytes:
    """16-bit mono PCM WAV; ``filler`` adds an Apple-style FLLR chunk first."""
    pcm = b"\0\0" * int(rate * seconds)
    fmt = struct.pack("<HHIIHH", 1, 1, rate, rate * 2, 2, 16)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    if filler:
        chunks += b"FLLR" + struct.pack("<I", filler) + b"\0" * filler
    chunks += b"data" + struct.pack("<I", len(pcm)) + pcm
    return b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks


# ── Recording length (what the STT seconds cap charges) ──────────────────────


def test_wav_length_is_read_from_the_header():
    clip = io.BytesIO(_wav(3.2, filler=4044))
    assert recording_seconds(clip) == 4  # rounded up: never under-charge
    assert clip.tell() == 0  # the transcriber reads the same upload next


def test_unreadable_audio_is_charged_as_a_full_recording():
    """A legacy m4a (or a lying header) must not make a clip free."""
    assert recording_seconds(io.BytesIO(b"\0\0\0\x18ftypM4A ")) == UNKNOWN_CLIP_SECONDS
    assert recording_seconds(io.BytesIO(b"RIFF\0\0\0\0WAVE")) == UNKNOWN_CLIP_SECONDS


# ── Limits are generous for a real player ────────────────────────────────────


def test_default_caps_clear_a_heavy_real_day():
    """A long road trip on Plus (1,000 questions a month): ~200 answers, ~1.5
    tries each, ≤ 15 s per recording, plus dictation. If a default dropped
    below that, paying players would be refused mid-trip."""
    s = Settings()
    tries = 200 * 1.5
    assert s.daily_cap_stt_seconds >= tries * 15
    assert s.daily_cap_stt_tokens >= tries + 50
    assert s.daily_cap_answer_attempts >= 10  # "again" a few times + #204 retries
    assert s.daily_cap_entitlement_syncs >= 30  # launches, foregrounds, purchases


# ── The counter ──────────────────────────────────────────────────────────────


async def test_the_request_that_crosses_passes_the_next_is_refused(db_sessionmaker):
    caps = UsageCaps(db_sessionmaker, now=lambda: _T0)
    await caps.consume("u1", STT_SECONDS, 90, 100)
    await caps.consume("u1", STT_SECONDS, 15, 100)  # 105: a long last answer is not cut
    with pytest.raises(DailyCapExceeded) as refused:
        await caps.consume("u1", STT_SECONDS, 1, 100)
    assert refused.value.resets_at == datetime(2026, 10, 17, tzinfo=timezone.utc)


async def test_caps_are_per_subject_per_metric_per_day(db_sessionmaker):
    """One abuser must not lock anyone else out; tomorrow starts from zero and
    yesterday's rows are gone (only today's are ever read)."""
    now = [_T0]
    caps = UsageCaps(db_sessionmaker, now=lambda: now[0])
    await caps.consume("abuser", answer_attempts("q1"), 1, 1)
    with pytest.raises(DailyCapExceeded):
        await caps.consume("abuser", answer_attempts("q1"), 1, 1)
    await caps.consume("abuser", answer_attempts("q2"), 1, 1)  # another question
    await caps.consume("friend", answer_attempts("q1"), 1, 1)  # another player

    now[0] = _T0 + timedelta(hours=2)  # past UTC midnight
    await caps.consume("abuser", answer_attempts("q1"), 1, 1)
    async with db_sessionmaker() as s:
        rows = (await s.execute(select(UsageCounter))).scalars().all()
    assert {r.usage_date for r in rows} == {now[0].date()}


async def test_a_counter_outage_never_blocks_a_player():
    def broken():
        raise ConnectionError("db down")

    await UsageCaps(broken).consume("u1", STT_SECONDS, 10, 1)  # no raise
    await UsageCaps(None).consume("u1", STT_SECONDS, 10, 1)  # no DB = no caps


# ── Routes ───────────────────────────────────────────────────────────────────


def _assert_plain_429(resp):
    """Not the quota body: iOS decodes `questions_used`/`upgrade_available`
    into the paywall. A plain 429 lands on "Too many requests" instead."""
    assert resp.status_code == 429
    detail = resp.json()["detail"]
    assert detail["code"] == "daily_cap"
    assert "questions_used" not in detail and "upgrade_available" not in detail
    assert int(resp.headers["retry-after"]) > 0


def _capped(h: _Harness, db_sessionmaker, monkeypatch, **limits) -> None:
    for name, value in limits.items():
        monkeypatch.setenv(f"DAILY_CAP_{name.upper()}", str(value))
    caps = UsageCaps(db_sessionmaker)
    h.app.dependency_overrides[deps.get_usage_caps] = lambda: caps
    h.transcriber.transcribe_with_quiz_context = AsyncMock(
        wraps=h.transcriber.transcribe_with_quiz_context
    )


async def test_voice_over_the_seconds_cap_is_refused_before_stt(
    client_for, db_sessionmaker, monkeypatch
):
    h = _Harness(_open())
    _capped(h, db_sessionmaker, monkeypatch, stt_seconds=20)
    c = await client_for(h)
    audio = {"audio": ("answer.wav", _wav(12), "audio/wav")}
    url = "/api/v1/voice/submit/s_185?question_id=q_mcq&include_audio=false"

    assert (await c.post(url, files=audio)).status_code != 429  # 12 s
    assert (await c.post(url, files=audio)).status_code != 429  # 24 s, crossed
    resp = await c.post(url, files=audio)

    _assert_plain_429(resp)
    assert resp.json()["detail"]["cap"] == "stt_seconds"
    assert h.transcriber.transcribe_with_quiz_context.await_count == 2


@pytest.mark.parametrize("route", ["text", "voice"])
async def test_one_question_cannot_be_resubmitted_forever(
    client_for, db_sessionmaker, monkeypatch, route
):
    """Re-submits of a graded question re-run STT and the judge for free."""
    h = _Harness(_open())
    _capped(h, db_sessionmaker, monkeypatch, answer_attempts=2)
    c = await client_for(h)
    submit = h.text if route == "text" else h.voice

    for _ in range(2):
        assert (await submit(c, "hmm what")).status_code == 400  # unheard, uncharged
    resp = await submit(c, "curling")

    _assert_plain_429(resp)
    assert resp.json()["detail"]["cap"] == "answer_attempts"
    assert h.parser.parse.await_count == 2  # only the first two reached the paid parser


async def test_an_unknown_question_id_opens_no_counter(
    client_for, db_sessionmaker, monkeypatch
):
    """A made-up id is a 409 first; otherwise every random id would be a row."""
    h = _Harness(_open())
    _capped(h, db_sessionmaker, monkeypatch, answer_attempts=5)
    c = await client_for(h)

    assert (await h.text(c, "curling", question_id="q_made_up")).status_code == 409
    async with db_sessionmaker() as s:
        rows = (await s.execute(select(UsageCounter))).all()
    assert rows == []


def _app(router, db_sessionmaker, monkeypatch, **limits) -> FastAPI:
    for name, value in limits.items():
        monkeypatch.setenv(f"DAILY_CAP_{name.upper()}", str(value))
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.state.auth_sessionmaker = db_sessionmaker
    app.include_router(router, prefix="/api/v1")
    app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
        subject_id="u_caps", is_legacy=False, authenticated=True
    )
    app.dependency_overrides[deps.get_usage_caps] = lambda: UsageCaps(db_sessionmaker)
    return app


async def test_realtime_tokens_stop_at_the_cap(db_sessionmaker, monkeypatch):
    """A token is a billable realtime STT session. Over the cap iOS gets an
    error from the token fetch, which it already answers by recording the
    answer in batch mode, so play goes on."""
    monkeypatch.setenv("ELEVENLABS_API_KEY", "fake-key")
    app = _app(misc_routes.router, db_sessionmaker, monkeypatch, stt_tokens=1)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        _mock_elevenlabs(monkeypatch, remaining=9000)  # after: it patches every client
        assert (await c.post("/api/v1/elevenlabs/token")).status_code == 200
        resp = await c.post("/api/v1/elevenlabs/token")
    _assert_plain_429(resp)
    assert resp.json()["detail"]["cap"] == "stt_tokens"


async def test_entitlement_sync_stops_at_the_cap(db_sessionmaker, monkeypatch):
    """Each sync is a RevenueCat REST call on our project-wide rate limit; iOS
    treats sync as best effort (the webhook still lands)."""
    monkeypatch.setenv("REVENUECAT_API_KEY", "rc-key")
    fetch = AsyncMock(return_value={})
    monkeypatch.setattr(rc_service, "fetch_rc_subscriber", fetch)
    monkeypatch.setattr(rc_service, "apply_sync_snapshot", AsyncMock())
    app = _app(
        entitlements_routes.router, db_sessionmaker, monkeypatch, entitlement_syncs=1
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.post("/api/v1/entitlements/sync")).status_code == 200
        resp = await c.post("/api/v1/entitlements/sync")
    _assert_plain_429(resp)
    assert fetch.await_count == 1
