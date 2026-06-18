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


def _store(sessionmaker, ttl_days=30, family_max_days=60) -> RefreshTokenStore:
    return RefreshTokenStore(
        sessionmaker, ttl_days=ttl_days, family_max_days=family_max_days
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
