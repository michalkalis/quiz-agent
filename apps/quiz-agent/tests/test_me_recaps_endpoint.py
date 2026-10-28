"""#213.3: ``/me/recaps`` endpoints, account erase and data export.

Why: the endpoint decides which snapshot a signed-in player sees, ``seen`` is the
badge on the Profile tab, and a recap is personal data derived from the player's
events, so erase and export must reach it like everything else.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from app.api.routes import me_recaps
from app.db.models import PlayerRecap
from sqlalchemy import select

from tests._stats_helpers import ans, game, store
from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _seed_anon_upgraded,
)
from tests.test_auth_me_erase_anon_trail import _make_anon
from tests.test_auth_me_erase_unlinks import _delete

pytestmark = pytest.mark.asyncio
OTHER = "someone-else"


def _app(db):
    app = _make_app(db)
    app.include_router(me_recaps.router, prefix="/api/v1")
    return app


def _prev_month(day: int) -> datetime:
    first = datetime.now(timezone.utc).replace(day=1, hour=12, minute=0, second=0)
    last = first - timedelta(days=1)
    return last.replace(day=day, hour=12, minute=0, second=0, microsecond=0)


async def _earn_month(db, subject):
    await store(
        db,
        game(subject, f"{subject}-a", _prev_month(3), [ans()] * 15, tz="UTC")
        + game(subject, f"{subject}-b", _prev_month(4), [ans()] * 15, tz="UTC"),
    )


async def _get(app, bearer):
    async with _asgi(app) as c:
        return await c.get("/api/v1/me/recaps", headers=_auth(bearer))


async def _post_seen(app, bearer, recap_id):
    async with _asgi(app) as c:
        return await c.post(f"/api/v1/me/recaps/{recap_id}/seen", headers=_auth(bearer))


async def _rows(db):
    async with db() as s:
        return (await s.execute(select(PlayerRecap))).scalars().all()


def _recap(subject, created_at, kind="month", period="2026-09-01"):
    from datetime import date

    return PlayerRecap(
        subject_id=subject,
        kind=kind,
        period_start=date.fromisoformat(period),
        payload={"cards": []},
        schema_version=1,
        created_at=created_at,
    )


async def test_get_creates_and_lists_recap_with_the_documented_shape(db_sessionmaker):
    """The app reads exactly these fields; kind stays a plain string."""
    app = _app(db_sessionmaker)
    anon, bearer = await _make_anon(db_sessionmaker)
    await _earn_month(db_sessionmaker, anon)

    body = (await _get(app, bearer)).json()

    (month,) = [r for r in body["recaps"] if r["kind"] == "month"]
    assert set(month) == {
        "id",
        "kind",
        "period_start",
        "created_at",
        "seen",
        "schema_version",
        "payload",
    }
    assert month["seen"] is False and month["payload"]["summary"]["answers"] == 30


async def test_linked_anon_recap_is_reused_not_duplicated_on_sign_in(db_sessionmaker):
    """Earned as anon, still the only month recap after signing in: the account
    gets no second row of its own."""
    app = _app(db_sessionmaker)
    anon, anon_bearer = await _make_anon(db_sessionmaker)
    await _earn_month(db_sessionmaker, anon)
    await _get(app, anon_bearer)

    user_id, bearer = await _make_account(db_sessionmaker)
    async with db_sessionmaker() as s:
        from app.db.models import AnonymousIdentity

        row = await s.get(AnonymousIdentity, anon)
        row.upgraded_to_user_id = user_id
        await s.commit()

    body = (await _get(app, bearer)).json()

    assert len([r for r in body["recaps"] if r["kind"] == "month"]) == 1
    assert {r.subject_id for r in await _rows(db_sessionmaker)} == {anon}


async def test_duplicate_period_keeps_the_oldest_snapshot(db_sessionmaker):
    """If two identities both hold a period (concurrent first opens), the one the
    player may already have seen wins."""
    app = _app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker)
    anon = await _seed_anon_upgraded(db_sessionmaker, user_id)
    old = datetime(2026, 9, 2, tzinfo=timezone.utc)
    async with db_sessionmaker() as s:
        s.add_all([_recap(user_id, old + timedelta(days=1)), _recap(anon, old)])
        await s.commit()

    body = (await _get(app, bearer)).json()

    (month,) = [r for r in body["recaps"] if r["kind"] == "month"]
    assert month["created_at"].startswith("2026-09-02")


async def test_seen_sets_once_and_foreign_recap_is_404(db_sessionmaker):
    """Marking seen clears the badge; someone else's recap id must not even
    confirm that it exists."""
    app = _app(db_sessionmaker)
    anon, bearer = await _make_anon(db_sessionmaker)
    _, other_bearer = await _make_anon(db_sessionmaker)
    await _earn_month(db_sessionmaker, anon)
    rid = next(r for r in (await _get(app, bearer)).json()["recaps"])["id"]

    assert (await _post_seen(app, other_bearer, rid)).status_code == 404
    assert (await _post_seen(app, bearer, str(uuid.uuid4()))).status_code == 404
    assert (await _post_seen(app, bearer, "not-a-uuid")).status_code == 404
    assert all(r.seen_at is None for r in await _rows(db_sessionmaker))

    assert (await _post_seen(app, bearer, rid)).status_code == 204
    first = next(iter(await _rows(db_sessionmaker))).seen_at
    assert (await _post_seen(app, bearer, rid)).status_code == 204
    assert next(iter(await _rows(db_sessionmaker))).seen_at == first
    assert next(r for r in (await _get(app, bearer)).json()["recaps"])["seen"] is True


async def test_unauthenticated_requests_are_401(db_sessionmaker):
    """Recaps belong to one identity; the grace path has none."""
    app = _app(db_sessionmaker)
    assert (await _get(app, None)).status_code == 401
    assert (await _post_seen(app, None, str(uuid.uuid4()))).status_code == 401


async def test_account_erase_removes_recaps_of_account_and_linked_anon(db_sessionmaker):
    """A recap is derived personal data: erasing the account must remove it,
    including snapshots earned before sign-in, and leave other players' alone."""
    app = _app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.recaps")
    anon = await _seed_anon_upgraded(db_sessionmaker, user_id)
    now = datetime.now(timezone.utc)
    async with db_sessionmaker() as s:
        s.add_all([_recap(user_id, now), _recap(anon, now), _recap(OTHER, now)])
        await s.commit()

    assert (await _delete(app, bearer)).status_code == 204

    assert {r.subject_id for r in await _rows(db_sessionmaker)} == {OTHER}


async def test_export_includes_recaps_of_account_and_linked_anon(db_sessionmaker):
    """GDPR export must list the snapshots, with the pre-sign-in ones too."""
    app = _app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.recexp")
    anon = await _seed_anon_upgraded(db_sessionmaker, user_id)
    now = datetime.now(timezone.utc)
    async with db_sessionmaker() as s:
        s.add_all(
            [
                _recap(user_id, now, "first", "2026-10-01"),
                _recap(anon, now, "month", "2026-09-01"),
                _recap(OTHER, now),
            ]
        )
        await s.commit()

    async with _asgi(app) as c:
        resp = await c.get("/api/v1/auth/me/export", headers=_auth(bearer))

    assert resp.status_code == 200, resp.text
    kinds = sorted(r["kind"] for r in resp.json()["player_recaps"])
    assert kinds == ["first", "month"]
