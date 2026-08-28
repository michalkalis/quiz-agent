"""POST /sessions must whitelist the X-Build-Channel header onto the session.

Intent: pending_review questions may reach TestFlight builds but never the App
Store version (founder rule, 2026-08-28). The route half of that gate is an
exact-literal comparison on the ``X-Build-Channel`` header — loosening it to a
substring/case-insensitive match, or renaming the header, would let arbitrary
clients widen the review filter, so these tests pin the literal. Companion
tests in ``test_question_retriever_filters.py`` pin the retriever half.
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

    def __init__(self, headers: dict | None = None) -> None:
        self.headers = headers or {}


@pytest.fixture(autouse=True)
def _no_rate_limit_no_auth(monkeypatch):
    # Rate limiting and subject resolution are orthogonal to this contract.
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)

    async def _fake_resolve(request, user_id, token_service, sessionmaker):
        return AuthSubject(subject_id="anon-test", is_legacy=True, authenticated=False)

    monkeypatch.setattr(
        "app.api.routes.sessions.resolve_session_subject", _fake_resolve
    )


async def _create(manager: SessionManager, headers: dict | None):
    response = await create_session(
        request=_Req(headers),
        body=CreateSessionRequest(),
        session_manager=manager,
        token_service=None,
        auth_sessionmaker=None,
    )
    return manager.get_session(response.session_id)


async def test_testflight_header_reaches_session():
    manager = SessionManager()
    session = await _create(manager, {"X-Build-Channel": "testflight"})
    assert session.build_channel == "testflight"


async def test_absent_header_leaves_channel_unset():
    # App Store builds send no header at all — the default must be the
    # approved-only serving path.
    manager = SessionManager()
    session = await _create(manager, None)
    assert session.build_channel is None


async def test_wrong_value_is_ignored():
    # Only the exact literal counts; anything else (case variants, other
    # channels, garbage) must never mark the session as TestFlight.
    manager = SessionManager()
    session = await _create(manager, {"X-Build-Channel": "TestFlight"})
    assert session.build_channel is None
