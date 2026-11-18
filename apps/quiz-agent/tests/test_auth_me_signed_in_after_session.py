"""``DELETE /auth/me`` and ``GET /auth/me/export`` for a signed-in player who has
started a quiz (#239 — app quality from idle subscription capacity, audit round 2).

Starting a quiz runs ``identity._touch_identity`` for the bearer's subject, which
upserts an ``anonymous_identities`` row even when that subject is a ``users.id``.
The account endpoints must still treat that caller as the account: a deletion
request from a signed-in player has to remove the account, revoke the Apple grant
and de-link the anon trail (GDPR Art. 17, App Store 5.1.1(v)), not just erase an
"anonymous" trail under the user id and answer 204 while the account lives on and
comes back on the next sign-in. The export likewise has to be the account's.
"""

from __future__ import annotations

import pytest

from app.auth.identity import _touch_identity
from app.db.models import AnonymousIdentity
from tests.test_auth_me_endpoints import (
    APPLE_REFRESH,
    RevokeRecorder,
    _anon,
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _seed_anon_upgraded,
    _seed_refresh,
    _seed_usage,
    _token_service,
    _user_exists,
)

pytestmark = pytest.mark.asyncio


async def test_signed_in_player_who_started_a_quiz_is_really_deleted(db_sessionmaker):
    recorder = RevokeRecorder()
    app = _make_app(db_sessionmaker, recorder=recorder)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.q")
    await _seed_usage(db_sessionmaker, user_id, 3)
    await _seed_refresh(db_sessionmaker, user_id)
    linked = await _seed_anon_upgraded(db_sessionmaker, user_id)
    # What POST /sessions does for every bearer, a users.id included.
    await _touch_identity(db_sessionmaker, user_id, is_legacy=False)

    async with _asgi(app) as c:
        first = await c.delete("/api/v1/auth/me", headers=_auth(bearer))
        second = await c.delete("/api/v1/auth/me", headers=_auth(bearer))

    assert first.status_code == 204, first.text
    # The account is gone, so signing in again cannot bring it back …
    assert not await _user_exists(db_sessionmaker, user_id)
    # … Apple's grant was severed with the stored token …
    assert [c["token"] for c in recorder.calls] == [APPLE_REFRESH]
    # … the pre-sign-in trail no longer points at the person …
    assert (await _anon(db_sessionmaker, linked)).upgraded_to_user_id is None
    # … and no identity row named after the deleted account is left behind.
    assert await _anon(db_sessionmaker, user_id) is None
    assert second.status_code == 404, second.text


async def test_signed_in_player_who_started_a_quiz_exports_their_account(
    db_sessionmaker,
):
    """The export must be the account's (Apple identity included), not an empty
    anonymous one that hides what the server holds about the person."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.qx")
    await _seed_usage(db_sessionmaker, user_id, 4)
    await _touch_identity(db_sessionmaker, user_id, is_legacy=False)

    async with _asgi(app) as c:
        resp = await c.get("/api/v1/auth/me/export", headers=_auth(bearer))

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["apple_sub"] == "apple.sub.qx"
    assert [r["questions_count"] for r in body["usage"]] == [4]


async def test_anonymous_player_still_erases_only_their_own_data(db_sessionmaker):
    """The anon path stays: a real anonymous caller is not mistaken for an
    account, its identity row stays (App Attest binding) and no revoke runs."""
    recorder = RevokeRecorder()
    app = _make_app(db_sessionmaker, recorder=recorder)
    anon_id = "anon-" + "1" * 32
    async with db_sessionmaker() as s:
        s.add(AnonymousIdentity(anon_id=anon_id))
        await s.commit()
    bearer = _token_service().create_access_token(anon_id)
    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))

    assert resp.status_code == 204, resp.text
    assert await _anon(db_sessionmaker, anon_id) is not None
    assert recorder.calls == []
