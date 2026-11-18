"""App Store Connect webhook → triage (#218 — crash and feedback automation, 218.3).

Why these matter: the endpoint is public, and every accepted delivery starts
an AI analysis in the private triage repo. So only a body signed with our
secret (Apple's ``x-apple-signature: hmacsha256=<hex>``) is forwarded; a
forged, tampered or unsigned one is a 401 and sends nothing; with no secret
configured nothing is accepted at all (503). Apple's ping and other event
types are acknowledged (200, so Apple does not retry) but not forwarded.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.api.routes import hooks

pytestmark = pytest.mark.asyncio

SECRET = "asc-test-secret"

FEEDBACK = {
    "data": {
        "type": "betaFeedbackScreenshotSubmissionCreated",
        "id": "4a9eacca-e53f-4006-85db-aa18c515663a",
        "version": 1,
        "attributes": {"timestamp": "2025-05-08T01:29:36.16Z"},
        "relationships": {
            "instance": {
                "data": {
                    "type": "betaFeedbackScreenshotSubmissions",
                    "id": "AD8JvKbr0BK0Cj9OnM6WO6I",
                }
            }
        },
    }
}


def _sign(body: bytes, secret: str = SECRET) -> str:
    return "hmacsha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


@pytest_asyncio.fixture
async def client(monkeypatch):
    monkeypatch.setenv(hooks.SECRET_ENV, SECRET)
    sent = AsyncMock(return_value=True)
    monkeypatch.setattr(hooks, "dispatch", sent)
    app = FastAPI()
    app.include_router(hooks.router, prefix="/api/v1")
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c, sent


async def _post(c, payload: dict, signature: str | None = "auto"):
    body = json.dumps(payload).encode()
    headers = {"content-type": "application/json"}
    if signature == "auto":
        headers["x-apple-signature"] = _sign(body)
    elif signature is not None:
        headers["x-apple-signature"] = signature
    return await c.post("/api/v1/hooks/asc", content=body, headers=headers)


async def test_signature_matches_apples_documented_example():
    # From "Configuring and parsing App Store Connect API webhook notifications".
    assert hooks.signature_ok(
        b"Hello, World!",
        "hmacsha256=7f062172b01cb00b53ca068614674a3d982a34062a0f5d37687d5e3377e54657",
        "This is my secret",
    )


async def test_signed_feedback_is_forwarded_with_the_submission_id(client):
    c, sent = client
    r = await _post(c, FEEDBACK)
    assert r.status_code == 200
    sent.assert_awaited_once()
    event_type, payload, _sm = sent.await_args.args
    assert event_type == "asc_feedback"
    assert payload["submission_id"] == "AD8JvKbr0BK0Cj9OnM6WO6I"


async def test_crash_report_is_forwarded_as_asc_crash(client):
    c, sent = client
    crash = json.loads(json.dumps(FEEDBACK))
    crash["data"]["type"] = "betaFeedbackCrashSubmissionCreated"
    assert (await _post(c, crash)).status_code == 200
    assert sent.await_args.args[0] == "asc_crash"


@pytest.mark.parametrize(
    "signature",
    [
        None,  # unsigned
        "hmacsha256=" + "0" * 64,  # forged
        _sign(b"another body"),  # replayed signature, tampered body
        _sign(json.dumps(FEEDBACK).encode(), "wrong-secret"),  # wrong secret
    ],
)
async def test_bad_or_missing_signature_is_401_and_sends_nothing(client, signature):
    c, sent = client
    r = await _post(c, FEEDBACK, signature=signature)
    assert r.status_code == 401
    sent.assert_not_awaited()


async def test_unconfigured_secret_refuses_everything(client, monkeypatch):
    c, sent = client
    monkeypatch.delenv(hooks.SECRET_ENV)
    assert (await _post(c, FEEDBACK)).status_code == 503
    sent.assert_not_awaited()


async def test_ping_is_acknowledged_but_not_forwarded(client):
    c, sent = client
    ping = {"data": {"type": "webhookPingCreated", "id": "p1", "version": 1}}
    assert (await _post(c, ping)).status_code == 200
    sent.assert_not_awaited()
