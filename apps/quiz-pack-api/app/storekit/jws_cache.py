"""JWS verify cache backed by Redis (issue #33 Task 1.11).

Lives in `app.storekit` (moved from `app.sse` — backend arch review
2026-07-18): caching a StoreKit chain-verify is a StoreKit concern, not an
SSE one.

Caches the result of a full ECDSA chain-verify in Redis for 60s.

Cache key: ``jws:verified:{sha256_hex(jws)[:16]}``

On a cache hit the JWS payload is decoded locally — no signature re-verification.
On a cache miss the full ``verifier.verify(jws)`` path runs and the key is set
(NX, EX 60) so concurrent racing requests both verify but only one writes.
"""

from __future__ import annotations

import base64
import hashlib
import json
from typing import Any

from redis.asyncio import Redis

from .models import SignedTransaction
from .verifier import AppleJWSVerifier


def _jws_cache_key(jws: str) -> str:
    return "jws:verified:" + hashlib.sha256(jws.encode()).hexdigest()[:16]


def _decode_jws_payload_locally(jws: str) -> SignedTransaction:
    """Decode the JWS payload without re-verifying the signature.

    Used on cache hit — the signature was already verified on the miss path and
    the 60s TTL is intentionally short so revoked/tampered tokens are re-checked
    quickly.
    """
    parts = jws.split(".")
    if len(parts) < 3:
        raise ValueError("malformed JWS: expected 3 dot-separated parts")
    # Add padding if needed (base64url)
    payload_b64 = parts[1] + "==" * (4 - len(parts[1]) % 4 or 4)
    raw = base64.urlsafe_b64decode(payload_b64)
    data: dict[str, Any] = json.loads(raw)
    return SignedTransaction.model_validate(data)


async def verify_jws_cached(
    jws: str,
    verifier: AppleJWSVerifier,
    redis_conn: Redis,
) -> SignedTransaction:
    """Return a ``SignedTransaction``, using a 60s Redis cache to skip re-verify.

    The cache stores an empty string as a sentinel (value is irrelevant — presence
    of the key means "this JWS was verified within the TTL window").  The decoded
    ``SignedTransaction`` is always reconstructed from the JWS payload, not stored
    in Redis, so we never cache sensitive transaction data.

    Raises the same exceptions as ``AppleJWSVerifier.verify()`` on cache miss.
    """
    key = _jws_cache_key(jws)

    hit = await redis_conn.exists(key)
    if hit:
        # Re-decode payload locally; no signature re-verification needed.
        return _decode_jws_payload_locally(jws)

    # Cache miss — full verify.
    tx = verifier.verify(jws)

    # SET ... NX EX 60: only sets if key is absent — a concurrent racing request
    # that also had a miss will both verify but only the first write wins.  Either
    # way the key is set within the same TTL window.
    await redis_conn.set(key, "", ex=60, nx=True)

    return tx
