"""Unit tests for `app.storekit.jws_cache.verify_jws_cached`.

This helper sits on the paid path twice — `POST /v1/orders/{id}/retry` and the
SSE stream authorize every call through it — and had no direct test: the only
coverage was incidental, via the e2e stream test. What it decides is who gets
to spend money, so each test below encodes one of its three contracts:

- cache MISS must run the full chain verify (nothing is trusted on first sight)
  and remember the result with a bounded TTL,
- cache HIT must skip re-verification yet still return the SAME transaction
  identity (that is the whole point of the cache, and a wrong local decode would
  attribute a purchase to the wrong transaction),
- a FAILED verify must never be cached as verified — a poisoned cache would turn
  one rejected forgery into a 60-second window where the same forged JWS is
  accepted without any signature check.

No Redis and no live Apple certs: an in-memory double for Redis (the pattern
tests/worker already uses — fakeredis is not a dependency of this app) and the
suite's in-memory test cert chain for the verifier.
"""

from __future__ import annotations

from typing import Any, Optional
from unittest.mock import AsyncMock, MagicMock

import pytest

from app.storekit import AppleJWSVerifier, JWSInvalid, SignedTransaction
from app.storekit.jws_cache import _jws_cache_key, verify_jws_cached
from tests.storekit._chain_fixtures import JWSFactory


class FakeRedis:
    """Minimal async Redis double covering `exists` + SET NX EX.

    Records the options each write used so a test can assert the TTL — the key
    must expire, or a refunded/revoked transaction would keep verifying forever.
    """

    def __init__(self) -> None:
        self.store: dict[str, str] = {}
        self.set_calls: list[dict[str, Any]] = []

    async def exists(self, key: str) -> int:
        return 1 if key in self.store else 0

    async def set(
        self,
        key: str,
        value: str,
        ex: Optional[int] = None,
        nx: bool = False,
    ) -> Optional[bool]:
        self.set_calls.append({"key": key, "ex": ex, "nx": nx})
        if nx and key in self.store:
            return None
        self.store[key] = value
        return True


@pytest.fixture
def verifier(test_chain) -> AppleJWSVerifier:
    return AppleJWSVerifier(
        root_cert=test_chain.root_cert,
        app_bundle_id="com.missinghue.hangs",
        environment="Sandbox",
    )


@pytest.fixture
def spy_verifier(verifier: AppleJWSVerifier) -> MagicMock:
    """The real verifier, wrapped so tests can count `verify` calls."""
    return MagicMock(wraps=verifier)


@pytest.fixture
def unrevoked_session() -> MagicMock:
    """A session double whose revocation lookup finds nothing.

    These tests are about *cache* semantics, so they keep the DB out. The
    revocation half of `verify_jws_cached` is covered against a real database
    in tests/api/test_appstore_notifications.py — including the case this
    double cannot express, a refund landing inside the cache window.
    """
    session = MagicMock()
    result = MagicMock()
    result.scalars.return_value.first.return_value = None
    session.execute = AsyncMock(return_value=result)
    return session


@pytest.mark.asyncio
async def test_cache_miss_verifies_once_and_caches(
    spy_verifier: MagicMock, make_jws: JWSFactory, unrevoked_session: MagicMock
) -> None:
    """First sight of a JWS: full chain verify, then a TTL-bounded cache entry."""
    jws = make_jws()
    redis = FakeRedis()

    tx = await verify_jws_cached(jws, spy_verifier, redis, unrevoked_session)

    assert isinstance(tx, SignedTransaction)
    assert tx.transaction_id == "1000000123456789"
    spy_verifier.verify.assert_called_once_with(jws)

    # Cached under this JWS's own key, with a bounded TTL (so a cert/chain
    # change is picked up promptly — revocation no longer rides on this TTL,
    # it is checked per call against the DB), and NX so two racing requests
    # can't clobber each other's window.
    assert _jws_cache_key(jws) in redis.store
    assert redis.set_calls == [{"key": _jws_cache_key(jws), "ex": 60, "nx": True}]


@pytest.mark.asyncio
async def test_cache_hit_skips_verification_but_keeps_identity(
    spy_verifier: MagicMock, make_jws: JWSFactory, unrevoked_session: MagicMock
) -> None:
    """Second call is served from cache: no re-verify, same transaction back.

    Both halves matter. No re-verify is why the cache exists (an SSE client
    reconnecting repeatedly would otherwise redo the ECDSA chain walk per
    request); same identity is what makes skipping safe — the hit path decodes
    the payload locally, so a sloppy decode would silently hand the caller a
    different transaction/product than the one that was verified.
    """
    jws = make_jws()
    redis = FakeRedis()

    first = await verify_jws_cached(jws, spy_verifier, redis, unrevoked_session)
    second = await verify_jws_cached(jws, spy_verifier, redis, unrevoked_session)

    spy_verifier.verify.assert_called_once()  # NOT called again on the hit
    assert second.transaction_id == first.transaction_id
    assert second.product_id == first.product_id
    assert second.bundle_id == first.bundle_id
    # One write only — the hit path must not refresh the TTL, or a client that
    # keeps polling would extend a revoked token's life indefinitely.
    assert len(redis.set_calls) == 1


@pytest.mark.asyncio
async def test_failed_verify_is_not_cached_as_valid(
    spy_verifier: MagicMock, make_jws: JWSFactory, unrevoked_session: MagicMock
) -> None:
    """A rejected JWS must raise and leave the cache untouched.

    If the key were written before (or despite) the verify, the next request
    carrying that same forged JWS would hit the cache and be accepted with no
    signature check at all — one rejected forgery buying a 60s window of free
    packs. So: the exception propagates, nothing is stored, and a retry is
    verified again from scratch rather than short-circuited.
    """
    forged = make_jws(tamper_signature=True)
    redis = FakeRedis()

    with pytest.raises(JWSInvalid, match="signature verification failed"):
        await verify_jws_cached(forged, spy_verifier, redis, unrevoked_session)

    assert redis.store == {}, "failed verification was cached as verified"
    assert redis.set_calls == []

    with pytest.raises(JWSInvalid):
        await verify_jws_cached(forged, spy_verifier, redis, unrevoked_session)
    assert spy_verifier.verify.call_count == 2  # re-verified, not served from cache
