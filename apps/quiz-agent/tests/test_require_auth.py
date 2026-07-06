"""Tests for require_bearer_or_grace — the high-cost-endpoint gate (#65).

A sync, DB-free sibling of resolve_session_subject for routes with no body
``user_id`` (Whisper transcribe, voice submit, TTS, ElevenLabs token). Same
authority rule: a *present* bearer must verify (else 401; 503 if auth is
unavailable); a *missing* bearer passes only during the LEGACY_USER_ID_GRACE
window, else 401. These pin that the gate can't be bypassed by simply omitting
the header once grace is flipped off.
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from app.auth.identity import require_bearer_or_grace
from app.auth.tokens import TokenService

_SECRET = "t" * 64


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


class _Url:
    path = "/api/v1/test-route"


class _Req:
    """Minimal stand-in for starlette Request (``.headers`` + ``.url.path``)."""

    url = _Url()

    def __init__(self, authorization: str | None = None) -> None:
        self.headers = {} if authorization is None else {"Authorization": authorization}


def test_valid_bearer_authenticates():
    ts = _token_service()
    token = ts.create_access_token("anon-real-subject")
    subject = require_bearer_or_grace(_Req(f"Bearer {token}"), ts)
    assert subject.subject_id == "anon-real-subject"
    assert subject.authenticated is True
    assert subject.is_legacy is False


def test_present_but_invalid_bearer_is_rejected():
    """A failed token must 401 — never silently fall through to the grace path
    (that would be an auth downgrade)."""
    with pytest.raises(HTTPException) as exc:
        require_bearer_or_grace(_Req("Bearer not-a-real-jwt"), _token_service())
    assert exc.value.status_code == 401


def test_no_bearer_grace_on_passes_as_legacy(monkeypatch):
    """With grace on, a header-less request passes as an unauthenticated legacy
    subject — so shipping the gate doesn't break the pre-auth iOS build."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    subject = require_bearer_or_grace(_Req(None), _token_service())
    assert subject.subject_id is None
    assert subject.authenticated is False
    assert subject.is_legacy is True


def test_grace_passthrough_is_logged(monkeypatch, caplog):
    """The grace pass-through must never be silent (#65, founder decision #5):
    each pass leaves a WARNING naming the route, so prod logs quantify how much
    traffic still depends on the grace window before the flag flips off."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    with caplog.at_level("WARNING", logger="app.auth.identity"):
        require_bearer_or_grace(_Req(None), _token_service())
    assert any(
        "AUTH GRACE" in r.message and "/api/v1/test-route" in r.message
        for r in caplog.records
    )


def test_authenticated_bearer_is_not_grace_logged(monkeypatch, caplog):
    """A verified bearer must not trip the grace warning — the log's value is
    that it counts only unauthenticated pass-throughs."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    ts = _token_service()
    token = ts.create_access_token("anon-real-subject")
    with caplog.at_level("WARNING", logger="app.auth.identity"):
        require_bearer_or_grace(_Req(f"Bearer {token}"), ts)
    assert not any("AUTH GRACE" in r.message for r in caplog.records)


def test_no_bearer_grace_off_rejects(monkeypatch):
    """Grace off → a header-less request is hard-rejected (the gate is live)."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    with pytest.raises(HTTPException) as exc:
        require_bearer_or_grace(_Req(None), _token_service())
    assert exc.value.status_code == 401


def test_present_bearer_without_token_service_is_503():
    """A present bearer when auth is unavailable must 503 — we can't verify it,
    so we fail loud rather than pass or 401. Handled before the grace branch, so
    the grace flag is irrelevant here."""
    with pytest.raises(HTTPException) as exc:
        require_bearer_or_grace(_Req("Bearer whatever"), None)
    assert exc.value.status_code == 503
