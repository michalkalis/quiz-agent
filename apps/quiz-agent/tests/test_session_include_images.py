"""POST /sessions must carry the client's image opt-in onto the session (#68).

Intent: the Home-screen "Image questions" toggle rides ``include_images`` on
the create-session body. If the route ever stops copying it onto the stored
session, the toggle becomes a silent no-op — the retriever (which reads
``session.include_images``) would treat every session as opted-out and the
user-facing setting would lie. Companion tests in
``test_question_retriever_filters.py`` pin the retriever half of the contract.
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
    # The route is rate-limited via slowapi (needs full app state) and resolves
    # the subject from the bearer token — both orthogonal to this contract.
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


async def test_include_images_defaults_off():
    manager = SessionManager()
    session = await _create(manager, CreateSessionRequest())
    assert session.include_images is False


async def test_include_images_opt_in_reaches_session():
    manager = SessionManager()
    session = await _create(manager, CreateSessionRequest(include_images=True))
    assert session.include_images is True
