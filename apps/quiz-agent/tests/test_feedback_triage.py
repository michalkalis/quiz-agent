"""In-app feedback → private triage repo (#218 — crash and feedback automation, 218.3).

Why these matter: a tester's report must always be saved and answered, even
when GitHub is down or slow; the bridge only runs after the response. The
triage repo holds no admin key, so the report travels inside the dispatch,
but without anything that identifies the player (no account id, no e-mail)
and without attachment bytes, and within GitHub's 10-property limit.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from types import SimpleNamespace

import httpx
import pytest

from app.triage import dispatch as dispatch_mod
from tests.test_feedback_routes import _bearer, client  # noqa: F401 — fixture

pytestmark = pytest.mark.asyncio


async def test_github_down_does_not_affect_feedback(client, monkeypatch):  # noqa: F811
    monkeypatch.setenv(dispatch_mod.TOKEN_ENV, "github_pat_x")
    attempts: list[dict] = []

    def down(request: httpx.Request) -> httpx.Response:
        attempts.append(json.loads(request.content))
        raise httpx.ConnectError("github unreachable")

    def failing_client(**kw):
        return httpx.AsyncClient(transport=httpx.MockTransport(down), **kw)

    monkeypatch.setattr(
        dispatch_mod,
        "httpx",
        SimpleNamespace(AsyncClient=failing_client, Timeout=httpx.Timeout),
    )
    resp = await client.post(
        "/api/v1/feedback",
        headers=_bearer("anon-secret-subject"),
        data={
            "message": "the timer froze",
            "metadata": '{"build": "83", "quiz_language": "sk"}',
            "app_version": "1.2",
        },
        files={"screenshot": ("s.png", b"\x89PNG-fake", "image/png")},
    )
    assert resp.status_code == 201
    assert len(attempts) == 1
    sent = attempts[0]
    assert sent["event_type"] == "app_feedback"
    payload = sent["client_payload"]
    assert payload["id"] == resp.json()["id"]
    assert payload["text"] == "the timer froze"
    assert payload["app"]["build"] == "83" and payload["quiz"]["language"] == "sk"
    assert payload["attachments"]["screenshot"] is True
    assert "anon-secret-subject" not in json.dumps(payload)


async def test_payload_is_anonymous_bounded_and_without_bytes():
    row = SimpleNamespace(
        id=uuid.uuid4(),
        user_id="acct-123",
        created_at=datetime(2026, 11, 2, tzinfo=timezone.utc),
        message="x" * 6000,
        metadata_={"device_model": "iPhone18,1", "email": "a@b.c"},
        app_version="1.2 (83)",
        screenshot=b"\x89PNG" * 1000,
        audio=None,
        logs="log tail",
    )
    payload = dispatch_mod.feedback_payload(row)
    assert len(payload) <= 10
    assert len(payload["text"]) == dispatch_mod.TEXT_MAX_CHARS
    assert payload["text_truncated"] is True
    assert payload["user"] and payload["user"] != "acct-123"
    # Same player → same id, so the triage can count reports per player.
    assert payload["user"] == dispatch_mod.feedback_payload(row)["user"]
    dumped = json.dumps(payload)
    assert "acct-123" not in dumped and "a@b.c" not in dumped and "PNG" not in dumped
    assert payload["attachments"] == {"screenshot": True, "audio": False, "logs": True}


async def test_local_test_run_never_reaches_the_real_triage_repo():
    """A developer's .env holds the real dispatch token; without the conftest
    guard every local run that saves feedback opened fake issues in the
    private triage repo (10 of them on 2026-11-02)."""
    assert dispatch_mod._token() == ""
