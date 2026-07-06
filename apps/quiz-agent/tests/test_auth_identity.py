"""Tests for subject resolution + legacy grace (issue #60, task 60.6).

The security claim: the subject a session is counted against comes from a
*verified* bearer token, not the spoofable body ``user_id``. These pin that a
valid token wins over a conflicting body id, a present-but-invalid token is
rejected (no silent downgrade), and the legacy ``user_id`` fallback is gated
both ways by ``LEGACY_USER_ID_GRACE``.
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.auth.identity import resolve_session_subject
from app.auth.tokens import TokenService
from app.db.models import AnonymousIdentity

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


class _Url:
    path = "/api/v1/sessions"


class _Req:
    """Minimal stand-in for starlette Request (``.headers`` + ``.url.path``)."""

    url = _Url()

    def __init__(self, authorization: str | None = None) -> None:
        self.headers = {} if authorization is None else {"Authorization": authorization}


async def test_valid_bearer_overrides_body_user_id(db_sessionmaker):
    """A spoofed body id must not win against a verified token — the subject is
    the token's ``sub``, regardless of what the body claims."""
    ts = _token_service()
    token = ts.create_access_token("anon-real-subject")
    req = _Req(f"Bearer {token}")

    subject = await resolve_session_subject(req, "dev_spoofed_id", ts, db_sessionmaker)

    assert subject.subject_id == "anon-real-subject"
    assert subject.authenticated is True
    assert subject.is_legacy is False


async def test_present_but_invalid_bearer_is_rejected(db_sessionmaker):
    """A failed token must 401 — never silently fall through to the weak body
    path (that would be an auth downgrade)."""
    req = _Req("Bearer not-a-real-jwt")
    with pytest.raises(HTTPException) as exc:
        await resolve_session_subject(req, "dev_x", _token_service(), db_sessionmaker)
    assert exc.value.status_code == 401


async def test_no_bearer_grace_on_uses_body_and_registers_legacy(
    db_sessionmaker, monkeypatch
):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    req = _Req(None)

    subject = await resolve_session_subject(
        req, "dev_legacy_id", _token_service(), db_sessionmaker
    )

    assert subject.subject_id == "dev_legacy_id"
    assert subject.authenticated is False
    assert subject.is_legacy is True

    # The legacy id is lazily registered as an is_legacy identity.
    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(AnonymousIdentity).where(
                    AnonymousIdentity.anon_id == "dev_legacy_id"
                )
            )
        ).scalar_one()
    assert row.is_legacy is True


async def test_no_bearer_grace_off_rejects(db_sessionmaker, monkeypatch):
    """With the grace flag off, an unauthenticated request is rejected — the
    spoofable body id is no longer accepted."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    req = _Req(None)
    with pytest.raises(HTTPException) as exc:
        await resolve_session_subject(
            req, "dev_legacy_id", _token_service(), db_sessionmaker
        )
    assert exc.value.status_code == 401
