"""Tests for the rotating refresh-token store (issue #60, task 60.3).

These assert the RFC 9700 intent, not just CRUD: rotation must invalidate the
old token (so a leaked token has a short useful life), replay of a used token
must revoke the *entire family* (theft containment), and tokens must live in the
DB only as hashes (a DB read must not yield usable tokens).
"""

from __future__ import annotations

import hashlib
from datetime import timedelta

import pytest
from sqlalchemy import select

from app.auth.refresh import (
    RefreshError,
    RefreshReuseDetected,
    RefreshTokenStore,
    _now,
)
from app.db.models import AnonymousIdentity, RefreshToken

pytestmark = pytest.mark.asyncio

ANON = "anon_test_subject"


async def _seed_identity(sessionmaker) -> None:
    async with sessionmaker() as s:
        s.add(AnonymousIdentity(anon_id=ANON))
        await s.commit()


def _store(
    sessionmaker, ttl_days=30, family_max_days=60, retry_grace_seconds=0
) -> RefreshTokenStore:
    # Default grace 0 = strict RFC 9700 detection (the reuse tests below assert
    # that mode). Production defaults to 60s (#88 lost-response grace); the
    # grace-on behaviour is exercised by the `_grace` tests.
    return RefreshTokenStore(
        sessionmaker,
        ttl_days=ttl_days,
        family_max_days=family_max_days,
        retry_grace_seconds=retry_grace_seconds,
    )


async def _issue_first(store, sessionmaker):
    async with sessionmaker() as s:
        issued = await store.issue(s, ANON)
        await s.commit()
    return issued


async def test_rotation_returns_new_token_and_same_subject(db_sessionmaker):
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker)
    first = await _issue_first(store, db_sessionmaker)

    result = await store.rotate(first.raw_token)

    assert result.anon_id == ANON
    assert result.refresh.raw_token != first.raw_token
    assert result.refresh.family_id == first.family_id  # same family


async def test_old_token_is_invalidated_after_rotation(db_sessionmaker):
    """The presented token is single-use: rotating it once, then presenting it
    again, is reuse → family revoked."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker)
    first = await _issue_first(store, db_sessionmaker)

    await store.rotate(first.raw_token)  # consumes `first`
    with pytest.raises(RefreshReuseDetected):
        await store.rotate(first.raw_token)


async def test_reuse_revokes_entire_family(db_sessionmaker):
    """After reuse is detected, even the otherwise-valid latest token in the
    family no longer works — theft containment, not just single-token revoke."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker)
    first = await _issue_first(store, db_sessionmaker)
    second = await store.rotate(first.raw_token)  # latest valid token

    with pytest.raises(RefreshReuseDetected):
        await store.rotate(first.raw_token)  # replay the consumed token

    # The latest (previously valid) token is now revoked too.
    with pytest.raises(RefreshError):
        await store.rotate(second.refresh.raw_token)


async def test_unknown_token_is_rejected(db_sessionmaker):
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker)
    with pytest.raises(RefreshError):
        await store.rotate("not-a-real-token")


async def test_expired_token_is_rejected(db_sessionmaker):
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker)
    first = await _issue_first(store, db_sessionmaker)

    # Force the stored token past its expiry.
    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(RefreshToken).where(
                    RefreshToken.token_hash
                    == hashlib.sha256(first.raw_token.encode()).hexdigest()
                )
            )
        ).scalar_one()
        row.expires_at = _now() - timedelta(seconds=1)
        await s.commit()

    with pytest.raises(RefreshError):
        await store.rotate(first.raw_token)


async def test_token_is_stored_only_as_hash(db_sessionmaker):
    """The raw token must never be persisted; only its SHA-256 hash is."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker)
    first = await _issue_first(store, db_sessionmaker)

    async with db_sessionmaker() as s:
        rows = (await s.execute(select(RefreshToken))).scalars().all()
    assert len(rows) == 1
    assert rows[0].token_hash != first.raw_token
    assert rows[0].token_hash == hashlib.sha256(first.raw_token.encode()).hexdigest()


async def test_family_absolute_age_cap_is_enforced(db_sessionmaker):
    """Past the family's absolute age cap, rotation is refused even for an
    un-used, un-expired token — forcing a fresh bootstrap."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker, ttl_days=30, family_max_days=60)
    first = await _issue_first(store, db_sessionmaker)

    # Age the family beyond the 60-day absolute cap (and keep it un-expired).
    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(RefreshToken).where(
                    RefreshToken.token_hash
                    == hashlib.sha256(first.raw_token.encode()).hexdigest()
                )
            )
        ).scalar_one()
        row.issued_at = _now() - timedelta(days=61)
        row.expires_at = _now() + timedelta(days=1)
        await s.commit()

    with pytest.raises(RefreshError):
        await store.rotate(first.raw_token)


# --- #88 lost-response reuse-grace ------------------------------------------


async def test_grace_recovers_lost_response(db_sessionmaker):
    """Replaying the just-used token within the grace window, while its
    successor is still unused, is a dropped rotation response (cellular blip) —
    recover with a fresh pair, retire the never-delivered successor, and keep
    the family alive so a signed-in user is not silently dropped to anonymous."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker, retry_grace_seconds=60)
    first = await _issue_first(store, db_sessionmaker)
    second = await store.rotate(first.raw_token)  # successor, never "received"

    # Re-present `first` — the client kept it because the rotation response was lost.
    recovered = await store.rotate(first.raw_token)

    # A fresh, distinct token is issued and the family still rotates.
    assert recovered.anon_id == ANON
    assert recovered.refresh.raw_token not in {
        first.raw_token,
        second.refresh.raw_token,
    }
    assert await store.rotate(recovered.refresh.raw_token)  # usable → family alive

    # The dangling successor is retired (it was never delivered to anyone).
    with pytest.raises(RefreshError):
        await store.rotate(second.refresh.raw_token)


async def test_grace_does_not_cover_older_token_reuse(db_sessionmaker):
    """Grace covers only the immediately-previous token. A token two rotations
    old — whose successor has already been used — is genuine reuse and revokes
    the whole family even inside the window (theft defence intact)."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker, retry_grace_seconds=60)
    first = await _issue_first(store, db_sessionmaker)
    second = await store.rotate(first.raw_token)  # first used
    third = await store.rotate(second.refresh.raw_token)  # second used → third

    # Replay `first`: its successor (`second`) is already used → theft path.
    with pytest.raises(RefreshReuseDetected):
        await store.rotate(first.raw_token)

    # The latest token is revoked too (family containment).
    with pytest.raises(RefreshError):
        await store.rotate(third.refresh.raw_token)


async def test_grace_expires_after_window(db_sessionmaker):
    """Past the grace window, a replay of the used token is reuse again — the
    recovery is bounded in time so a stolen token cannot be replayed forever."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker, retry_grace_seconds=60)
    first = await _issue_first(store, db_sessionmaker)
    await store.rotate(first.raw_token)  # first used; successor still unused

    # Age `first.used_at` past the 60s window.
    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(RefreshToken).where(
                    RefreshToken.token_hash
                    == hashlib.sha256(first.raw_token.encode()).hexdigest()
                )
            )
        ).scalar_one()
        row.used_at = _now() - timedelta(seconds=120)
        await s.commit()

    with pytest.raises(RefreshReuseDetected):
        await store.rotate(first.raw_token)


async def test_grace_recovers_repeated_lost_response(db_sessionmaker):
    """A SECOND dropped response (the grace reply is also lost, or a duplicate
    request races) must still recover — grace re-issues from the family's current
    live token rather than falsely revoking the family on the stale, already-
    retired successor (the #88 review finding). Theft defence is untouched: the
    moment ANY token in the family is actually used, replays flip to revocation
    (covered by test_grace_does_not_cover_older_token_reuse)."""
    await _seed_identity(db_sessionmaker)
    store = _store(db_sessionmaker, retry_grace_seconds=60)
    first = await _issue_first(store, db_sessionmaker)
    await store.rotate(first.raw_token)  # successor unused (response lost)
    r1 = await store.rotate(first.raw_token)  # recovery 1 (reply also "lost")

    # Re-present `first` yet again: recovery 2 must NOT revoke the family.
    r2 = await store.rotate(first.raw_token)

    assert r2.refresh.raw_token not in {first.raw_token, r1.refresh.raw_token}
    assert await store.rotate(r2.refresh.raw_token)  # family still alive
