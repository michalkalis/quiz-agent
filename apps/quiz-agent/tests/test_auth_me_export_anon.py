"""``GET /auth/me/export`` for anonymous users (#193 — beta hardening).

The app offers "Export my data" before sign-in, and an anonymous identity has
server-side data from first launch, so the GDPR Art. 20 export must answer for
it instead of 404. For an account, data from before sign-in must appear exactly
once: sign-in already sums the anon's usage into the account's rows.
"""

from __future__ import annotations

from datetime import timedelta

import pytest
from app.usage.account_merge import merge_anonymous_identity

from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _seed_usage,
    _today,
)
from tests.test_auth_me_erase_anon_trail import _make_anon

pytestmark = pytest.mark.asyncio


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
