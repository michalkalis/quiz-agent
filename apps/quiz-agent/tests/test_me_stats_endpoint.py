"""#213.2: ``GET /api/v1/me/stats``.

Why: the endpoint is what makes a pre-sign-in game count for the signed-in
account, and the response must stay readable by app builds that predate any
future card, so kinds/states/units are plain strings.
"""

from __future__ import annotations

import pytest
from app.api.routes import me_stats

from tests._stats_helpers import ans, at, game, store
from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _seed_anon_upgraded,
)
from tests.test_auth_me_erase_anon_trail import _make_anon

pytestmark = pytest.mark.asyncio


def _app(db):
    app = _make_app(db)
    app.include_router(me_stats.router, prefix="/api/v1")
    return app


async def _get(app, bearer):
    async with _asgi(app) as c:
        return await c.get("/api/v1/me/stats", headers=_auth(bearer))


async def test_account_stats_include_games_played_as_the_linked_anon(db_sessionmaker):
    """A player signs in after playing; their earlier games must not vanish."""
    app = _app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker)
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    await store(
        db_sessionmaker,
        game(anon_id, "a", at(1), [ans()] * 3)
        + game(user_id, "b", at(2), [ans()] * 2)
        + game("stranger", "c", at(3), [ans()] * 7),
    )

    resp = await _get(app, bearer)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    totals = next(c for c in body["cards"] if c["kind"] == "totals")
    assert totals["data"]["answers"] == 5 and totals["data"]["games"] == 2
    assert body["first_recap_progress"]["answers"] == 5
    assert {c["state"] for c in body["cards"]} <= {"locked", "unlocked"}


async def test_anonymous_player_sees_only_their_own_stats(db_sessionmaker):
    """Anonymous players have stats on their device identity, and only theirs."""
    app = _app(db_sessionmaker)
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await store(
        db_sessionmaker,
        game(anon_id, "a", at(1), [ans()] * 4)
        + game("someone-else", "b", at(2), [ans()] * 9),
    )
    body = (await _get(app, bearer)).json()
    totals = next(c for c in body["cards"] if c["kind"] == "totals")
    assert totals["data"]["answers"] == 4


async def test_request_without_a_verified_bearer_is_401(db_sessionmaker):
    """Stats belong to one identity; the unauthenticated grace path has none."""
    resp = await _get(_app(db_sessionmaker), None)
    assert resp.status_code == 401
