"""Subject resolution for incoming requests (issue #60, task 60.6).

The usage limit is only as trustworthy as the *subject* it counts against. Today
the subject is the client-supplied ``user_id`` body field on ``POST /sessions`` —
a spoofable string (change it → fresh free bucket). This module derives the
subject from a verified ``Authorization: Bearer`` access token instead.

Decision: a *present* bearer is authoritative — if it fails verification we 401,
we do **not** silently fall back (that would let an attacker downgrade to the
weak path). The body ``user_id`` fallback is only for requests with *no* bearer,
and only while ``LEGACY_USER_ID_GRACE`` is on (the ~30-day migration window). When
the flag is off, an unauthenticated request is rejected outright.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import HTTPException, Request
from sqlalchemy.dialects.postgresql import insert as pg_insert

from ..db.models import AnonymousIdentity
from .tokens import TokenError, TokenService

logger = logging.getLogger(__name__)

_GRACE_TRUTHY = {"1", "true", "on", "yes"}


def legacy_grace_enabled() -> bool:
    """Whether the legacy ``user_id`` fallback is active (default on).

    Read live (not cached at import) so the flag can be flipped — and tests can
    monkeypatch — without a process restart."""
    return os.getenv("LEGACY_USER_ID_GRACE", "on").strip().lower() in _GRACE_TRUTHY


@dataclass(frozen=True)
class AuthSubject:
    """The resolved subject for a request.

    ``authenticated`` is True only when it came from a verified bearer token;
    ``is_legacy`` marks the grace-window ``user_id`` fallback path."""

    subject_id: str | None
    is_legacy: bool
    authenticated: bool


def _bearer_token(request: Request) -> str | None:
    """Return the token from an ``Authorization: Bearer <t>`` header, or None.

    A missing header or non-bearer scheme is "no bearer" (→ grace path), *not*
    an error. Only a present bearer with a bad token is treated as a failed auth
    attempt (handled by the caller as 401)."""
    header = request.headers.get("Authorization")
    if not header:
        return None
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


async def _touch_identity(sessionmaker, anon_id: str, *, is_legacy: bool) -> None:
    """Upsert the identity row and bump ``last_seen_at``.

    For the bearer path this is self-healing (creates the row if somehow
    missing); for the grace path it lazily registers the legacy ``dev_…`` id as
    an ``is_legacy=true`` identity. We never *downgrade* an existing row to
    legacy — on conflict only ``last_seen_at`` is updated."""
    if sessionmaker is None:
        return
    now = datetime.now(timezone.utc)
    async with sessionmaker() as session:
        await session.execute(
            pg_insert(AnonymousIdentity)
            .values(
                anon_id=anon_id,
                is_legacy=is_legacy,
                created_at=now,
                last_seen_at=now,
            )
            .on_conflict_do_update(
                index_elements=["anon_id"], set_={"last_seen_at": now}
            )
        )
        await session.commit()


async def resolve_session_subject(
    request: Request,
    body_user_id: str | None,
    token_service: TokenService | None,
    sessionmaker,
) -> AuthSubject:
    """Resolve the subject for a session-creating request (see module docstring)."""
    token = _bearer_token(request)
    if token is not None:
        if token_service is None:
            raise HTTPException(status_code=503, detail="Auth unavailable")
        try:
            payload = token_service.decode_access_token(token)
        except TokenError:
            raise HTTPException(
                status_code=401, detail="Invalid or expired access token"
            )
        subject = payload["sub"]
        await _touch_identity(sessionmaker, subject, is_legacy=False)
        return AuthSubject(subject_id=subject, is_legacy=False, authenticated=True)

    # No bearer presented.
    if not legacy_grace_enabled():
        raise HTTPException(status_code=401, detail="Authentication required")

    # Grace window: trust the client-supplied id, registering it as legacy.
    if body_user_id:
        await _touch_identity(sessionmaker, body_user_id, is_legacy=True)
    return AuthSubject(subject_id=body_user_id, is_legacy=True, authenticated=False)
