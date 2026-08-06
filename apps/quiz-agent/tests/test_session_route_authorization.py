"""#144 — session route authorization: the session id is not a credential.

Before this, everything after ``POST /sessions`` trusted the session id alone.
That id serves a paid custom pack's private questions, spends the owner's
freemium quota and drives GPT-eval + TTS spend, so a leaked id (URL, client log,
Sentry breadcrumb, support screenshot) worked as a bearer token for someone
else's content — the #96 broken-access-control fix was verified once at creation
and never again.

These tests encode three things a refactor must not lose:

1. **Inventory** — every ``/sessions/{session_id}`` route (plus ``/voice/submit``)
   declares the auth dependency *and* runs the shared ownership helper. Asserted
   over the live router table, so a newly added route fails here instead of
   shipping ungated.
2. **Cross-subject denial is 404, never 403** — a valid bearer for a different
   subject learns nothing about whether the session exists.
3. **Fail closed** — no bearer, or a grace-window subject that cannot be
   verified, is denied even while ``LEGACY_USER_ID_GRACE`` is on.
"""

from __future__ import annotations

import inspect
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from fastapi.params import Depends as DependsParam
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api import deps
from app.api.routes import quiz as quiz_routes
from app.api.routes import sessions as sessions_routes
from app.api.routes import tts as tts_routes
from app.api.routes import voice as voice_routes
from app.auth.tokens import TokenError
from app.rate_limit import limiter
from app.session.manager import SessionManager
from app.voice.transcriber import VoiceTranscriber
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question

pytestmark = pytest.mark.asyncio

SUBJECT_A = "subject-a"
SUBJECT_B = "subject-b"
PACK_ID = "e5b8c1a2-0000-4000-8000-000000000abc"
PACK_SECRET = "Which street did the founder grow up on?"


# ── Route inventory ──────────────────────────────────────────────────────────


def _session_scoped_routes():
    """(method, path, endpoint) for every route keyed by a session id."""
    found = []
    for router in (
        sessions_routes.router,
        quiz_routes.router,
        voice_routes.router,
        tts_routes.router,
    ):
        for route in router.routes:
            path = getattr(route, "path", "")
            if "{session_id}" not in path:
                continue
            for method in sorted(set(route.methods) - {"HEAD", "OPTIONS"}):
                found.append((method, path, route.endpoint))
    return found


def test_every_session_scoped_route_is_gated():
    """Inventory, not eyeballing: each session-scoped route must both declare
    ``require_auth_or_grace`` and call the shared ownership helper."""
    routes = _session_scoped_routes()
    # Guard against the inventory silently collapsing to zero (e.g. a router
    # rename) and reporting green.
    assert len(routes) >= 12, routes

    ungated = []
    for method, path, endpoint in routes:
        func = inspect.unwrap(endpoint)
        declares_auth = any(
            isinstance(p.default, DependsParam)
            and p.default.dependency is deps.require_auth_or_grace
            for p in inspect.signature(func).parameters.values()
        )
        checks_owner = "require_session_ownership" in inspect.getsource(func)
        if not (declares_auth and checks_owner):
            ungated.append((method, path, declares_auth, checks_owner))
    assert not ungated, f"session-scoped routes missing the #144 gate: {ungated}"


# ── App under test ───────────────────────────────────────────────────────────


class _FakeTokenService:
    """Decodes a bearer whose token IS the subject id; anything else is invalid."""

    def decode_access_token(self, token: str) -> dict:
        if token not in (SUBJECT_A, SUBJECT_B):
            raise TokenError("bad token")
        return {"sub": token}


class _StubTranscriber:
    SUPPORTED_FORMATS = VoiceTranscriber.SUPPORTED_FORMATS

    def is_supported_format(self, filename):  # pragma: no cover - never reached
        return True


def _pack_question() -> Question:
    return Question(
        id="q-pack-1",
        question=PACK_SECRET,
        type="text",
        correct_answer="Baker Street",
        topic="Custom",
        category="general",
        difficulty="medium",
        review_status="pending_review",
    )


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    monkeypatch.setattr(limiter, "enabled", False)


@pytest.fixture
def manager() -> SessionManager:
    return SessionManager()


@pytest.fixture
def retriever() -> MagicMock:
    r = MagicMock()
    r.get.return_value = _pack_question()
    r.get_next_question.return_value = _pack_question()
    r.count.return_value = 1
    return r


@pytest.fixture
def app(manager: SessionManager, retriever: MagicMock) -> FastAPI:
    application = FastAPI()
    application.state.limiter = limiter
    application.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    for router in (
        sessions_routes.router,
        quiz_routes.router,
        voice_routes.router,
        tts_routes.router,
    ):
        application.include_router(router, prefix="/api/v1")

    feedback = MagicMock()
    feedback.submit_rating = AsyncMock(return_value=(True, "ok"))
    feedback.flag_question = AsyncMock(return_value=(True, "ok"))
    flow = MagicMock()
    flow.process_answer = AsyncMock()
    tts = MagicMock()
    tts.synthesize_question = AsyncMock(return_value=b"audio")
    tts.synthesize = AsyncMock(return_value=b"audio")

    overrides = {
        deps.get_session_manager: lambda: manager,
        deps.get_question_retriever: lambda: retriever,
        deps.get_feedback_service: lambda: feedback,
        deps.get_quiz_flow: lambda: flow,
        deps.get_tts_service: lambda: tts,
        deps.get_voice_transcriber: _StubTranscriber,
        deps.get_usage_tracker: lambda: None,
        deps.get_translation_service: lambda: None,
        deps.get_token_service: _FakeTokenService,
    }
    application.dependency_overrides.update(overrides)
    return application


@pytest_asyncio.fixture
async def client(app: FastAPI):
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


def _owned_session(manager: SessionManager, *, pack: bool = False):
    session = manager.create_session(user_id=SUBJECT_A)
    session.phase = SessionPhase.ASKING
    session.current_question_id = "q-pack-1"
    session.asked_question_ids = ["q-pack-1"]
    session.participants = []
    if pack:
        session.pack_id = PACK_ID
    manager.update_session(session)
    return session


def _bearer(subject: str) -> dict:
    return {"Authorization": f"Bearer {subject}"}


_AUDIO = {"audio": ("answer.mp3", b"fake-bytes", "audio/mpeg")}


def _requests(session_id: str):
    """Every session-scoped call the spec's denial matrix must cover."""
    return [
        ("POST", f"/api/v1/sessions/{session_id}/start", {"json": {}}),
        ("POST", f"/api/v1/sessions/{session_id}/input", {"json": {"input": "Paris"}}),
        ("GET", f"/api/v1/sessions/{session_id}/question", {}),
        ("POST", f"/api/v1/sessions/{session_id}/rate", {"json": {"rating": 5}}),
        ("POST", f"/api/v1/sessions/{session_id}/flag", {"json": {"reason": "wrong"}}),
        ("GET", f"/api/v1/sessions/{session_id}", {}),
        ("DELETE", f"/api/v1/sessions/{session_id}", {}),
        ("POST", f"/api/v1/sessions/{session_id}/extend", {}),
        ("POST", f"/api/v1/voice/submit/{session_id}", {"files": _AUDIO}),
        (
            "POST",
            f"/api/v1/sessions/{session_id}/participants",
            {"json": {"display_name": "Bob"}},
        ),
        ("DELETE", f"/api/v1/sessions/{session_id}/participants/p1", {}),
        ("GET", f"/api/v1/sessions/{session_id}/question/audio", {}),
        ("GET", f"/api/v1/sessions/{session_id}/feedback/correct/audio", {}),
    ]


# ── Cross-subject denial ─────────────────────────────────────────────────────


async def test_other_subject_gets_404_on_every_session_route(client, manager):
    """B holds a valid bearer and A's session id — the id must buy nothing, and
    the denial must be indistinguishable from "no such session"."""
    session = _owned_session(manager)

    for method, url, kwargs in _requests(session.session_id):
        resp = await client.request(method, url, headers=_bearer(SUBJECT_B), **kwargs)
        assert resp.status_code == 404, f"{method} {url} → {resp.status_code}"
        assert resp.json()["detail"] == "Session not found or expired", (
            f"{method} {url}"
        )

    # ...and nothing was mutated or spent on B's behalf.
    assert manager.get_session(session.session_id) is not None


async def test_denied_delete_does_not_destroy_the_session(client, manager):
    """Authorize before mutating: a stranger's DELETE must not take effect."""
    session = _owned_session(manager)

    resp = await client.delete(
        f"/api/v1/sessions/{session.session_id}", headers=_bearer(SUBJECT_B)
    )

    assert resp.status_code == 404
    assert manager.get_session(session.session_id) is not None


async def test_other_subject_cannot_read_a_custom_packs_questions(
    client, manager, retriever
):
    """The #96 gap end to end: pack content is authorized once at creation, so
    the serve path is where a leaked id would have paid off."""
    session = _owned_session(manager, pack=True)

    resp = await client.get(
        f"/api/v1/sessions/{session.session_id}/question", headers=_bearer(SUBJECT_B)
    )

    assert resp.status_code == 404
    assert PACK_SECRET not in resp.text
    retriever.get.assert_not_called()  # denied before the store is even touched


async def test_other_subject_cannot_hear_a_custom_packs_question(client, manager):
    """The audio route speaks the same question text — same gate."""
    session = _owned_session(manager, pack=True)

    resp = await client.get(
        f"/api/v1/sessions/{session.session_id}/question/audio",
        headers=_bearer(SUBJECT_B),
    )

    assert resp.status_code == 404


# ── Fail closed ──────────────────────────────────────────────────────────────


async def test_no_bearer_is_denied_even_during_the_grace_window(
    client, manager, monkeypatch
):
    """``require_auth_or_grace`` lets a bearer-less request through while grace is
    on, with ``authenticated=False`` and no subject id. That is not enough to own
    a session, so the helper — not the route — must deny it."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    session = _owned_session(manager)

    for method, url, kwargs in _requests(session.session_id):
        resp = await client.request(method, url, **kwargs)
        assert resp.status_code == 404, f"{method} {url} → {resp.status_code}"


async def test_no_bearer_is_denied_with_grace_off(client, manager, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    session = _owned_session(manager)

    resp = await client.get(f"/api/v1/sessions/{session.session_id}")

    assert resp.status_code == 401


async def test_invalid_bearer_is_rejected(client, manager):
    session = _owned_session(manager)

    resp = await client.get(
        f"/api/v1/sessions/{session.session_id}",
        headers={"Authorization": "Bearer forged-token"},
    )

    assert resp.status_code == 401


async def test_ownerless_session_is_denied(client, manager):
    """A session with no ``user_id`` (pre-#89 shape) belongs to nobody — it must
    not become readable by every authenticated caller."""
    session = manager.create_session(user_id=None)
    manager.update_session(session)

    resp = await client.get(
        f"/api/v1/sessions/{session.session_id}", headers=_bearer(SUBJECT_A)
    )

    assert resp.status_code == 404


# ── Owner's happy path is unchanged ──────────────────────────────────────────


async def test_owner_still_reads_their_own_session_and_question(
    client, manager, retriever
):
    session = _owned_session(manager, pack=True)

    state = await client.get(
        f"/api/v1/sessions/{session.session_id}", headers=_bearer(SUBJECT_A)
    )
    question = await client.get(
        f"/api/v1/sessions/{session.session_id}/question", headers=_bearer(SUBJECT_A)
    )

    assert state.status_code == 200
    assert state.json()["session_id"] == session.session_id
    assert question.status_code == 200
    assert question.json()["question"]["question"] == PACK_SECRET
    retriever.get.assert_called_once()
