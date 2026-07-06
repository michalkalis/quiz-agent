"""POST /sessions must wire the category filter onto ``preferred_categories`` (#82).

Intent: the question retriever filters on ``session.preferred_categories``
(question_retriever.py) — NOT ``session.category``, which is display-only.
Before #82 nothing populated the list, so the Home category picker was a
silent end-to-end no-op. These tests pin the wiring for both the new
multi-select ``categories`` list and the legacy single ``category`` field,
so neither client generation can regress into decoration.
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


async def test_no_categories_leaves_filter_empty():
    manager = SessionManager()
    session = await _create(manager, CreateSessionRequest())
    assert session.preferred_categories == []


async def test_categories_list_reaches_preferred_categories():
    manager = SessionManager()
    session = await _create(
        manager, CreateSessionRequest(categories=["kids", "disney"])
    )
    assert session.preferred_categories == ["kids", "disney"]


async def test_legacy_single_category_reaches_preferred_categories():
    """Pre-#82 clients send one ``category`` string — it must filter too,
    not just decorate the session."""
    manager = SessionManager()
    session = await _create(manager, CreateSessionRequest(category="adults"))
    assert session.preferred_categories == ["adults"]
    assert session.category == "adults"


async def test_categories_list_wins_over_legacy_category():
    manager = SessionManager()
    session = await _create(
        manager,
        CreateSessionRequest(categories=["kids"], category="adults"),
    )
    assert session.preferred_categories == ["kids"]
