"""Session language acceptance is two-tiered — #168 batch translation SK/CS, T21.

Why this exists: the old ``^[a-z]{2}$`` pattern on ``CreateSessionRequest``
accepted any two letters, so a garbage or hidden language opened a session that
the translation gate (DD1) would then starve of questions — an empty quiz
instead of a clear rejection.

The fix has to land in two phases, and these tests pin the *soft* one:

* an unknown code (``zz``) is rejected — nothing the app ships can send it;
* a known but currently hidden code (``de``) is still **accepted**, loudly.
  Every installed TestFlight build offers all ten languages and cannot be
  updated from the server, so 422-ing ``de`` today would break live sessions on
  the founder's device. The WARNING is what makes the acceptance visible in
  logs while the client catches up (T22), and T26 flips this same case to 422
  once the gated build is confirmed on the device — at which point
  ``test_legacy_language_accepted_with_deprecation_warning`` is expected to be
  replaced, not silently deleted.
"""

from __future__ import annotations

import logging

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api import deps
from app.api.deps import CreateSessionRequest
from app.api.routes import sessions as session_routes
from app.auth.identity import AuthSubject
from app.rate_limit import limiter
from app.session.manager import SessionManager

# Only the HTTP-level tests are async; the model-level ones are marked below.


@pytest.fixture
def app(monkeypatch) -> FastAPI:
    """The real /sessions route with auth and rate limiting stubbed out.

    Both are orthogonal to language acceptance, but they run *before* the body
    reaches the session, so the test would otherwise measure them instead.
    """

    async def _fake_resolve(request, user_id, token_service, sessionmaker):
        return AuthSubject(subject_id="anon-test", is_legacy=True, authenticated=False)

    monkeypatch.setattr(
        "app.api.routes.sessions.resolve_session_subject", _fake_resolve
    )
    monkeypatch.setattr(limiter, "enabled", False)

    manager = SessionManager()
    api = FastAPI()
    api.state.limiter = limiter
    api.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    api.include_router(session_routes.router, prefix="/api/v1")
    api.dependency_overrides[deps.get_session_manager] = lambda: manager
    api.dependency_overrides[deps.get_token_service] = lambda: None
    api.dependency_overrides[deps.get_auth_sessionmaker] = lambda: None
    return api


async def _create_session(app: FastAPI, language: str):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        return await client.post("/api/v1/sessions", json={"language": language})


@pytest.mark.asyncio
async def test_legacy_language_accepted_with_deprecation_warning(app, caplog):
    """A hidden-but-known language still opens a session, and says so in the log."""
    with caplog.at_level(logging.WARNING, logger="app.api.deps"):
        response = await _create_session(app, "de")

    # 201 is this route's success code; the point is that it is not a 422.
    assert response.status_code == 201, response.text
    assert response.json()["language"] == "de"

    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert warnings, "a non-servable language must be logged, not silently accepted"
    assert any("de" in r.getMessage() for r in warnings), (
        "the warning must name the code so ops can see which hidden language "
        "is still in use before T26 hardens it to a 422"
    )


@pytest.mark.asyncio
async def test_unknown_code_rejected(app):
    """``zz`` is not a language the data model knows — reject it outright."""
    response = await _create_session(app, "zz")
    assert response.status_code == 422, response.text


@pytest.mark.asyncio
async def test_servable_language_accepted_without_warning(app, caplog):
    """The happy path must stay quiet, or the warning becomes noise."""
    with caplog.at_level(logging.WARNING, logger="app.api.deps"):
        response = await _create_session(app, "sk")

    assert response.status_code == 201, response.text
    assert not [r for r in caplog.records if r.levelno == logging.WARNING]


def test_servable_list_is_env_driven(monkeypatch, caplog):
    """Re-enabling a language is an env flip, not a deploy (#168 DD14).

    Same code, different ``SERVABLE_QUIZ_LANGUAGES``: ``pl`` goes from
    warned-about to silently fine.
    """
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,sk,cs")
    with caplog.at_level(logging.WARNING, logger="app.api.deps"):
        assert CreateSessionRequest(language="pl").language == "pl"
    assert [r for r in caplog.records if r.levelno == logging.WARNING]

    caplog.clear()
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,sk,cs,pl")
    with caplog.at_level(logging.WARNING, logger="app.api.deps"):
        assert CreateSessionRequest(language="pl").language == "pl"
    assert not [r for r in caplog.records if r.levelno == logging.WARNING]


def test_language_is_normalised():
    """Clients that send ``SK``/`` sk `` must not become a second, unmatched code."""
    assert CreateSessionRequest(language="SK").language == "sk"


def test_default_language_is_english():
    assert CreateSessionRequest().language == "en"


def test_three_letter_code_rejected():
    """The old pattern rejected these on shape; the new check must too."""
    with pytest.raises(ValidationError):
        CreateSessionRequest(language="eng")
