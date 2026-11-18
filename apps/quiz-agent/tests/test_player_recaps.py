"""#213.3: lazy recap snapshots.

Why: a recap is a keepsake the player shares. It must appear exactly when the
play earned it, cover exactly its own calendar window in the player's own
timezone, and never change afterwards or appear twice, whatever the thresholds,
the events or the devices do later.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import pytest
from app.db.models import PlayerRecap
from app.player_stats.player_type import player_type
from app.player_stats.recaps import ensure_recaps
from sqlalchemy import select

from tests._stats_helpers import ans, game, store

P = "player-1"
OCT5 = datetime(2026, 10, 5, 12, tzinfo=timezone.utc)


def d(month, day, hour=12, minute=0, year=2026):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)


async def ensure(db, ids=(P,), now=OCT5, caller=None):
    async with db() as s:
        await ensure_recaps(s, caller or ids[0], list(ids), now)
        await s.commit()


async def recaps(db, kind=None):
    async with db() as s:
        rows = (await s.execute(select(PlayerRecap))).scalars().all()
    return [r for r in rows if kind in (None, r.kind)]


def september(subject, first, second, tz="UTC"):
    """Two September games (on different days) with the given answer counts."""
    return game(subject, "sep-a", d(9, 3), [ans()] * first, tz=tz) + game(
        subject, "sep-b", d(9, 4), [ans()] * second, tz=tz
    )


@pytest.mark.asyncio
async def test_month_recap_exists_at_30_answers_not_at_29(db_sessionmaker):
    """30 answers on 2 days is the promise of a meaningful month; one below must
    not produce a recap that would read as a thin, embarrassing summary."""
    await store(db_sessionmaker, september(P, 15, 14))
    await ensure(db_sessionmaker)
    assert await recaps(db_sessionmaker, "month") == []

    await store(db_sessionmaker, game(P, "sep-c", d(9, 5), [ans()], tz="UTC"))
    await ensure(db_sessionmaker)
    (row,) = await recaps(db_sessionmaker, "month")
    assert str(row.period_start) == "2026-09-01" and row.subject_id == P
    assert row.payload["summary"]["answers"] == 30 and row.schema_version == 1


@pytest.mark.asyncio
async def test_month_recap_needs_two_play_days(db_sessionmaker):
    """30 answers from one binge is not a month of play."""
    await store(db_sessionmaker, game(P, "one", d(9, 3), [ans()] * 30, tz="UTC"))
    await ensure(db_sessionmaker)
    assert await recaps(db_sessionmaker, "month") == []


@pytest.mark.asyncio
async def test_snapshot_is_never_recomputed_or_duplicated(db_sessionmaker):
    """A recap the player already saw or shared must not change when more events
    show up or when the app asks again."""
    await store(db_sessionmaker, september(P, 15, 15))
    await ensure(db_sessionmaker)
    (before,) = await recaps(db_sessionmaker, "month")

    await store(db_sessionmaker, game(P, "late", d(9, 20), [ans()] * 40, tz="UTC"))
    await ensure(db_sessionmaker)

    (after,) = await recaps(db_sessionmaker, "month")
    assert after.id == before.id and after.payload == before.payload
    assert after.payload["summary"]["answers"] == 30


@pytest.mark.asyncio
async def test_only_the_previous_month_is_created(db_sessionmaker):
    """No backfill: August and the running October never get a month recap."""
    await store(
        db_sessionmaker,
        game(P, "aug-a", d(8, 3), [ans()] * 20, tz="UTC")
        + game(P, "aug-b", d(8, 4), [ans()] * 20, tz="UTC")
        + september(P, 15, 15)
        + game(P, "oct-a", d(10, 2), [ans()] * 20, tz="UTC")
        + game(P, "oct-b", d(10, 3), [ans()] * 20, tz="UTC"),
    )
    await ensure(db_sessionmaker)
    assert [str(r.period_start) for r in await recaps(db_sessionmaker, "month")] == [
        "2026-09-01"
    ]


@pytest.mark.asyncio
async def test_month_boundary_follows_the_players_timezone(db_sessionmaker):
    """Auckland is 12h ahead: 12:30 UTC on Aug 31 is already September there.
    The same events must land in different months depending on the player's zone,
    otherwise a late-evening game counts toward the wrong recap."""
    rows = september(P, 14, 15, tz="Pacific/Auckland") + game(
        P, "edge", d(8, 31, 12, 30), [ans()], tz="Pacific/Auckland"
    )
    await store(db_sessionmaker, rows)
    await ensure(db_sessionmaker)
    (row,) = await recaps(db_sessionmaker, "month")
    assert row.payload["summary"]["answers"] == 30  # edge game is local Sep 1

    utc = "other"
    await store(
        db_sessionmaker,
        september(utc, 14, 15) + game(utc, "edge", d(8, 31, 12, 30), [ans()], tz="UTC"),
    )
    await ensure(db_sessionmaker, ids=(utc,))
    assert [
        r for r in await recaps(db_sessionmaker, "month") if r.subject_id == utc
    ] == []


@pytest.mark.asyncio
async def test_changing_timezone_does_not_create_a_second_row(db_sessionmaker):
    """Travelling must not mint a second recap for a month already held."""
    await store(db_sessionmaker, september(P, 15, 15, tz="Europe/Bratislava"))
    await ensure(db_sessionmaker)
    await store(
        db_sessionmaker, game(P, "trip", d(10, 4), [ans()], tz="Pacific/Auckland")
    )
    await ensure(db_sessionmaker)
    assert len(await recaps(db_sessionmaker, "month")) == 1


@pytest.mark.asyncio
async def test_linked_anon_snapshot_is_reused_after_sign_in(db_sessionmaker):
    """A recap earned as an anonymous player must not be created again for the
    account that adopts that anon, or the player would see it twice."""
    anon, user = "anon-1", "user-1"
    await store(db_sessionmaker, september(anon, 15, 15))
    await ensure(db_sessionmaker, ids=(anon,))
    await ensure(db_sessionmaker, ids=(user, anon))
    (row,) = await recaps(db_sessionmaker, "month")
    assert row.subject_id == anon


@pytest.mark.asyncio
async def test_year_recap_only_from_december_and_without_december(db_sessionmaker):
    """The yearly recap lands once December starts, covers Jan 1 to Nov 30 and
    leaves December for next year's."""
    rows = []
    for i in range(10):
        rows += game(P, f"y{i}", d(3, 1 + i), [ans()] * 15, tz="UTC")
    rows += game(P, "dec", d(12, 2), [ans()] * 10, tz="UTC")
    await store(db_sessionmaker, rows)

    await ensure(db_sessionmaker, now=d(11, 30, 23))
    assert await recaps(db_sessionmaker, "year") == []

    await ensure(db_sessionmaker, now=d(12, 5))
    (row,) = await recaps(db_sessionmaker, "year")
    assert str(row.period_start) == "2026-01-01"
    assert row.payload["summary"]["answers"] == 150


@pytest.mark.asyncio
async def test_year_recap_needs_150_answers(db_sessionmaker):
    """149 answers over a year is not enough to say something about it."""
    rows = []
    for i in range(10):
        rows += game(P, f"y{i}", d(3, 1 + i), [ans()] * (15 if i else 14), tz="UTC")
    await store(db_sessionmaker, rows)
    await ensure(db_sessionmaker, now=d(12, 5))
    assert await recaps(db_sessionmaker, "year") == []


@pytest.mark.asyncio
async def test_first_recap_once_ever_at_60_answers_on_3_days(db_sessionmaker):
    """The first recap rewards the early play once; later calls (and a later
    month) must never mint another, and 2 days of play is not enough."""
    rows = game(P, "f1", d(10, 1), [ans()] * 30, tz="UTC") + game(
        P, "f2", d(10, 2), [ans()] * 30, tz="UTC"
    )
    await store(db_sessionmaker, rows)
    await ensure(db_sessionmaker, now=d(10, 3))
    assert await recaps(db_sessionmaker, "first") == []

    await store(db_sessionmaker, game(P, "f3", d(10, 3), [ans()], tz="UTC"))
    await ensure(db_sessionmaker, now=d(10, 4))
    (row,) = await recaps(db_sessionmaker, "first")
    assert str(row.period_start) == "2026-10-04"

    await ensure(db_sessionmaker, now=d(11, 20))
    assert len(await recaps(db_sessionmaker, "first")) == 1


@pytest.mark.asyncio
async def test_concurrent_calls_make_one_row(db_sessionmaker):
    """The app can fire two requests at once; the unique key + DO NOTHING must
    leave a single snapshot instead of an error or a duplicate."""
    await store(db_sessionmaker, september(P, 15, 15))
    await asyncio.gather(ensure(db_sessionmaker), ensure(db_sessionmaker))
    assert len(await recaps(db_sessionmaker, "month")) == 1


@pytest.mark.asyncio
async def test_night_games_make_a_night_owl_snapshot(db_sessionmaker):
    """The type is stored in the snapshot, computed from the window's cards."""
    rows = []
    for i in range(6):
        rows += game(P, f"n{i}", d(10, 1 + i % 3, 23), [ans()] * 10, tz="UTC")
    await store(db_sessionmaker, rows)
    await ensure(db_sessionmaker, now=d(10, 5))
    (row,) = await recaps(db_sessionmaker, "first")
    assert row.payload["player_type"] == "night_owl"


def _cards(**over):
    base = {
        "when": {"state": "unlocked", "data": {"games": 10, "breakdown": {"night": 3}}},
        "where": {
            "state": "unlocked",
            "data": {"games": 10, "breakdown": {"car": 4, "speaker": 6}},
        },
        "best_category": {"state": "unlocked", "data": {"standout": False}},
    }
    base.update(over)
    return base


def test_player_type_rules_first_match_wins_at_their_lines():
    """Each rule has an exact line, and the order decides players who qualify
    for several (night owl beats everything, explorer is the fallback)."""
    slow = (50, 5000.0)
    assert player_type(_cards(), slow) == "all_rounder"
    night = {"state": "unlocked", "data": {"games": 10, "breakdown": {"night": 4}}}
    assert player_type(_cards(when=night), slow) == "night_owl"
    car = {"state": "unlocked", "data": {"games": 10, "breakdown": {"car": 5}}}
    assert player_type(_cards(where=car), slow) == "road_tripper"
    assert player_type(_cards(where=car, when=night), slow) == "night_owl"
    assert player_type(_cards(), (20, 2999.0)) == "speedster"
    assert player_type(_cards(), (20, 3000.0)) == "all_rounder"
    assert player_type(_cards(), (19, 1000.0)) == "all_rounder"
    star = {"state": "unlocked", "data": {"standout": True}}
    assert player_type(_cards(best_category=star), slow) == "specialist"
    assert player_type({}, slow) == "explorer"
