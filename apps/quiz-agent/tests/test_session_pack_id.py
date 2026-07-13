"""POST /sessions must thread ``pack_id`` onto the session (#95).

Intent: playing a delivered custom quiz pack is a session-creation-time choice —
the client sends the pack id and the whole session must be scoped to it (the
retriever filters on ``session.pack_id`` and the free-quota gate is bypassed).
If this wiring regresses, a "play pack" tap silently starts a normal
shared-corpus quiz that also burns the user's free monthly quota.
"""

from __future__ import annotations

import pytest

from app.api.deps import CreateSessionRequest
from app.api.routes.sessions import create_session
from app.auth.identity import AuthSubject
from app.session.manager import SessionManager

pytestmark = pytest.mark.asyncio


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


async def _create(manager: SessionManager, body: CreateSessionRequest):
    response = await create_session(
        request=_Req(),
        body=body,
        session_manager=manager,
        token_service=None,
        auth_sessionmaker=None,
    )
    return manager.get_session(response.session_id)


async def test_pack_id_reaches_session():
    manager = SessionManager()
    session = await _create(
        manager, CreateSessionRequest(pack_id="e5b8c1a2-0000-4000-8000-000000000abc")
    )
    assert session.pack_id == "e5b8c1a2-0000-4000-8000-000000000abc"


async def test_absent_pack_id_leaves_session_unscoped():
    manager = SessionManager()
    session = await _create(manager, CreateSessionRequest())
    assert session.pack_id is None
