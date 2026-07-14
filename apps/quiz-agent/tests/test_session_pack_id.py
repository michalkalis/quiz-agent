"""POST /sessions threads ``pack_id`` onto the session, but only for its owner (#95, #96).

Intent: playing a delivered custom quiz pack is a session-creation-time choice —
the client sends the pack id and the whole session is scoped to it (the retriever
filters on ``session.pack_id`` and the free-quota gate is bypassed). Because that
scoping serves private paid content AND skips the quota, ``create_session`` must
first verify the authenticated subject owns the pack (#96 review). These tests pin
the control flow both ways: an owned pack reaches the session; an un-owned pack, or
one that can't be verified (no DB), is refused with 404 — never silently trusted.
The real ownership SQL is pinned separately against Postgres in
``tests/db/test_pack_ownership.py``.
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from app.api.deps import CreateSessionRequest
from app.api.routes.sessions import create_session
from app.auth.identity import AuthSubject
from app.session.manager import SessionManager

pytestmark = pytest.mark.asyncio

_PACK_ID = "e5b8c1a2-0000-4000-8000-000000000abc"


class _Url:
    path = "/api/v1/sessions"


class _Req:
    """Minimal stand-in for starlette Request (headers + url only)."""

    url = _Url()
    headers: dict = {}


@pytest.fixture(autouse=True)
def _no_rate_limit_no_auth(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)

    async def _fake_resolve(request, user_id, token_service, sessionmaker):
        return AuthSubject(subject_id="anon-test", is_legacy=True, authenticated=False)

    monkeypatch.setattr(
        "app.api.routes.sessions.resolve_session_subject", _fake_resolve
    )


# ── Fake async sessionmaker: control-flow only (the real SQL is a DB test) ────


class _FakeResult:
    def __init__(self, row):
        self._row = row

    def first(self):
        return self._row


class _FakeDB:
    def __init__(self, row):
        self._row = row

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def execute(self, *args, **kwargs):
        return _FakeResult(self._row)


def _sessionmaker(owns: bool):
    """Fake ``async_sessionmaker``: ``owns`` decides whether the ownership SELECT
    returns a row. It ignores the SQL, so it verifies branching, not the query —
    that is ``tests/db/test_pack_ownership.py``'s job against real Postgres."""
    row = (1,) if owns else None

    def _maker():
        return _FakeDB(row)

    return _maker


async def _create(
    manager: SessionManager, body: CreateSessionRequest, auth_sessionmaker=None
):
    response = await create_session(
        request=_Req(),
        body=body,
        session_manager=manager,
        token_service=None,
        auth_sessionmaker=auth_sessionmaker,
    )
    return manager.get_session(response.session_id)


async def test_owned_pack_id_reaches_session():
    manager = SessionManager()
    session = await _create(
        manager,
        CreateSessionRequest(pack_id=_PACK_ID),
        auth_sessionmaker=_sessionmaker(owns=True),
    )
    assert session.pack_id == _PACK_ID


async def test_unowned_pack_id_is_rejected():
    # The security guard: an authenticated caller supplying a pack id they do not
    # own (a guessed/leaked id, or another user's pack) must be refused — not handed
    # the pack's private content plus a free-quota bypass. 404 keeps existence opaque.
    manager = SessionManager()
    with pytest.raises(HTTPException) as exc:
        await _create(
            manager,
            CreateSessionRequest(pack_id=_PACK_ID),
            auth_sessionmaker=_sessionmaker(owns=False),
        )
    assert exc.value.status_code == 404


async def test_pack_id_without_auth_db_is_rejected():
    # Ownership is un-verifiable with no auth DB → fail closed. Never fall back to
    # trusting the client-supplied id.
    manager = SessionManager()
    with pytest.raises(HTTPException) as exc:
        await _create(
            manager,
            CreateSessionRequest(pack_id=_PACK_ID),
            auth_sessionmaker=None,
        )
    assert exc.value.status_code == 404


async def test_absent_pack_id_leaves_session_unscoped():
    manager = SessionManager()
    session = await _create(manager, CreateSessionRequest())
    assert session.pack_id is None
