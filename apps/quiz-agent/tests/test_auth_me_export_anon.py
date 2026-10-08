"""``GET /auth/me/export`` for anonymous users and the full data trail (#193 —
beta hardening).

The app offers "Export my data" before sign-in, and an anonymous identity has
server-side data from first launch, so the GDPR Art. 15/20 export must answer
for it instead of 404. For an account, data from before sign-in must appear
exactly once: sign-in already sums the anon's usage into the account's rows,
but leaves feedback, analytics events and pack orders under the anon id.
"""

from __future__ import annotations

import base64
from datetime import timedelta

import pytest
from app.db.models import AnalyticsEvent, Feedback
from app.usage.account_merge import merge_anonymous_identity
from sqlalchemy import text

from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _seed_anon_upgraded,
    _seed_usage,
    _today,
)
from tests.test_auth_me_erase_anon_trail import _make_anon
from tests.test_auth_me_erase_unlinks import _seed_order

pytestmark = pytest.mark.asyncio

OTHER = "someone-else"
AUDIO = b"RIFF-raw-dictation-audio-bytes"


async def _export(app, bearer):
    async with _asgi(app) as c:
        return await c.get("/api/v1/auth/me/export", headers=_auth(bearer))


async def test_anonymous_user_can_export_their_own_data(db_sessionmaker):
    """An anon gets its own usage history (and nobody else's); there is no Apple
    identity behind it, so ``apple_sub`` is null rather than invented."""
    app = _make_app(db_sessionmaker)
    anon_id, bearer = await _make_anon(db_sessionmaker)
    other_id, _ = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon_id, 3, day=_today() - timedelta(days=1))
    await _seed_usage(db_sessionmaker, anon_id, 5)
    await _seed_usage(db_sessionmaker, other_id, 99)

    resp = await _export(app, bearer)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["apple_sub"] is None
    assert body["created_at"]
    assert [r["questions_count"] for r in body["usage"]] == [3, 5]


async def test_account_export_counts_pre_sign_in_usage_exactly_once(db_sessionmaker):
    """Sign-in folds the anon's usage into the account; the export must show it
    once, not add the (frozen) anon rows on top and double the person's history."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.exp2")
    anon_id, _ = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon_id, 4)
    async with db_sessionmaker() as s:
        await merge_anonymous_identity(s, anon_id, user_id)
        await s.commit()
    await _seed_usage(db_sessionmaker, user_id, 2, day=_today() - timedelta(days=1))

    body = (await _export(app, bearer)).json()

    assert [r["questions_count"] for r in body["usage"]] == [2, 4]


# ── Personal-data trail: feedback, analytics, pack orders (Art. 15/20) ───────


async def _seed_feedback_and_event(db, subject_id: str, label: str) -> None:
    async with db() as s:
        s.add(
            Feedback(
                user_id=subject_id,
                message=label,
                audio=AUDIO,
                audio_content_type="audio/wav",
            )
        )
        s.add(AnalyticsEvent(name=f"ev-{label}", subject_id=subject_id, source="ios"))
        await s.commit()


async def _drop_orders(db, *order_ids) -> None:
    async with db() as s:  # packs cascade with their order
        for order_id in order_ids:
            await s.execute(
                text("DELETE FROM generation_orders WHERE id = :a"), {"a": order_id}
            )
        await s.commit()


async def test_account_export_includes_trail_from_before_and_after_sign_in(
    db_sessionmaker,
):
    """Sign-in does not re-key feedback, events or orders, so the account's export
    must read them under its linked anon ids too — and never another person's.
    Attachments are listed by type; their bytes never travel in the export."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.trail")
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    await _seed_feedback_and_event(db_sessionmaker, anon_id, "before")
    await _seed_feedback_and_event(db_sessionmaker, user_id, "after")
    await _seed_feedback_and_event(db_sessionmaker, OTHER, "stranger")
    orders = [
        await _seed_order(db_sessionmaker, anon_id, "pack before"),
        await _seed_order(db_sessionmaker, OTHER, "stranger pack"),
    ]
    try:
        resp = await _export(app, bearer)
    finally:
        await _drop_orders(db_sessionmaker, *orders)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert sorted(f["message"] for f in body["feedback"]) == ["after", "before"]
    assert body["feedback"][0]["attachments"] == [
        {"kind": "audio", "content_type": "audio/wav"}
    ]
    assert sorted(e["name"] for e in body["analytics_events"]) == [
        "ev-after",
        "ev-before",
    ]
    assert [o["prompt"] for o in body["pack_orders"]] == ["pack before"]
    assert "stranger" not in resp.text
    assert AUDIO.decode() not in resp.text
    assert base64.b64encode(AUDIO).decode() not in resp.text


async def test_anonymous_export_includes_its_trail(db_sessionmaker):
    """An anonymous user's feedback, events and orders are theirs to see too."""
    app = _make_app(db_sessionmaker)
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _seed_feedback_and_event(db_sessionmaker, anon_id, "mine")
    order_id = await _seed_order(db_sessionmaker, anon_id, "anon pack")
    try:
        body = (await _export(app, bearer)).json()
    finally:
        await _drop_orders(db_sessionmaker, order_id)

    assert [f["message"] for f in body["feedback"]] == ["mine"]
    assert [e["name"] for e in body["analytics_events"]] == ["ev-mine"]
    (order,) = body["pack_orders"]
    assert (order["id"], order["prompt"]) == (str(order_id), "anon pack")
