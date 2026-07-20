"""POST/GET /api/v1/feedback — the beta in-app feedback inbox (issue #109).

Pins the contract the founder locked in-session: dictated feedback + optional
screenshot/audio/log attachments land in our own Postgres table (not Sentry),
gated the same way every other high-cost endpoint is (`require_auth_or_grace`
+ a 5/min IP cap), with server-enforced size caps (413) so a runaway
attachment can't blow up the row, and a `feedback.received` Sentry breadcrumb
only fires when Sentry is actually configured. The admin read routes reuse
the exact `verify_admin_key` dependency from #91 rather than a second
hand-rolled compare — so a missing `X-Admin-Key` header 422s at the FastAPI
validation layer (the dependency's `Header(...)` is required) while a
present-but-wrong key 401s inside the constant-time compare.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.routes import feedback as feedback_routes
from app.auth.tokens import TokenService
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64
_ADMIN_KEY = "super-secret-admin-key"


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _bearer(subject: str = "anon-feedback-subject") -> dict[str, str]:
    return {"Authorization": f"Bearer {_token_service().create_access_token(subject)}"}


@pytest_asyncio.fixture
async def client(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    monkeypatch.setenv("ADMIN_API_KEY", _ADMIN_KEY)
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(feedback_routes.router, prefix="/api/v1")
    app.state.token_service = _token_service()
    app.state.auth_sessionmaker = db_sessionmaker
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


def _sentry_active():
    """Patch sentry_sdk so the route sees an active client without a real DSN."""
    return patch.object(
        feedback_routes.sentry_sdk,
        "get_client",
        return_value=MagicMock(is_active=lambda: True),
    )


async def test_happy_path_multipart_insert_and_detail_read(client):
    """Message + all three attachments land in one row, and the admin detail
    read returns them back out (base64) — the round trip the sheet depends on."""
    with (
        _sentry_active(),
        patch.object(feedback_routes.sentry_sdk, "capture_message") as mock_capture,
    ):
        resp = await client.post(
            "/api/v1/feedback",
            headers=_bearer(),
            data={
                "message": "the mic cuts out sometimes",
                "metadata": '{"quizState": "asking"}',
                "app_version": "1.2.3 (45)",
            },
            files={
                "screenshot": ("s.png", b"\x89PNG-fake-bytes", "image/png"),
                "audio": ("a.wav", b"RIFF-fake-audio", "audio/wav"),
                "logs": ("l.txt", b"log line 1\nlog line 2", "text/plain"),
            },
        )
    assert resp.status_code == 201
    feedback_id = resp.json()["id"]
    assert feedback_id

    # feedback.received fired with the id + a message excerpt (#109 design).
    mock_capture.assert_called_once()
    assert feedback_id in mock_capture.call_args[0][0]
    assert "the mic cuts out" in mock_capture.call_args[0][0]

    detail = await client.get(
        f"/api/v1/feedback/{feedback_id}", headers={"X-Admin-Key": _ADMIN_KEY}
    )
    assert detail.status_code == 200
    body = detail.json()
    assert body["message"] == "the mic cuts out sometimes"
    assert body["metadata"] == {"quizState": "asking"}
    assert body["app_version"] == "1.2.3 (45)"
    assert body["logs"] == "log line 1\nlog line 2"
    assert body["screenshot_base64"] is not None
    assert body["screenshot_content_type"] == "image/png"
    assert body["audio_base64"] is not None
    assert body["audio_content_type"] == "audio/wav"


async def test_sentry_not_called_when_unconfigured(client):
    """No Sentry DSN in this test process — the route must not blow up trying
    to notify, and must not fabricate a call (mirrors real dev/test envs)."""
    with patch.object(feedback_routes.sentry_sdk, "capture_message") as mock_capture:
        resp = await client.post(
            "/api/v1/feedback", headers=_bearer(), data={"message": "quiet env"}
        )
    assert resp.status_code == 201
    mock_capture.assert_not_called()


async def test_auth_required(client):
    resp = await client.post("/api/v1/feedback", data={"message": "hi"})
    assert resp.status_code == 401


async def test_size_cap_413_screenshot_over_limit(client):
    oversized = b"x" * (feedback_routes.SCREENSHOT_MAX_BYTES + 1)
    resp = await client.post(
        "/api/v1/feedback",
        headers=_bearer(),
        data={"message": "too big"},
        files={"screenshot": ("s.png", oversized, "image/png")},
    )
    assert resp.status_code == 413


async def test_size_cap_413_message_over_limit(client):
    resp = await client.post(
        "/api/v1/feedback",
        headers=_bearer(),
        data={"message": "x" * (feedback_routes.MESSAGE_MAX_CHARS + 1)},
    )
    assert resp.status_code == 413


async def test_bad_metadata_json_rejected_400(client):
    resp = await client.post(
        "/api/v1/feedback",
        headers=_bearer(),
        data={"message": "hi", "metadata": "{not json"},
    )
    assert resp.status_code == 400


async def test_rate_limited_to_5_per_minute(client):
    headers = _bearer()
    for i in range(5):
        resp = await client.post(
            "/api/v1/feedback", headers=headers, data={"message": f"msg {i}"}
        )
        assert resp.status_code == 201
    resp = await client.post(
        "/api/v1/feedback", headers=headers, data={"message": "6th, over the cap"}
    )
    assert resp.status_code == 429


async def test_list_is_newest_first_and_carries_no_blob_bytes(client):
    """The list route is for browsing at a glance — sizes/flags, never the
    attachment bytes themselves (those are a separate, deliberate detail GET)."""
    first = await client.post(
        "/api/v1/feedback", headers=_bearer(), data={"message": "first"}
    )
    second = await client.post(
        "/api/v1/feedback",
        headers=_bearer(),
        data={"message": "second, with a screenshot"},
        files={"screenshot": ("s.png", b"abc", "image/png")},
    )
    assert first.status_code == 201 and second.status_code == 201

    listing = await client.get("/api/v1/feedback", headers={"X-Admin-Key": _ADMIN_KEY})
    assert listing.status_code == 200
    body = listing.json()
    assert body["total"] == 2
    assert [item["message"] for item in body["items"]] == [
        "second, with a screenshot",
        "first",
    ]
    newest = body["items"][0]
    assert newest["has_screenshot"] is True
    assert newest["screenshot_size"] == 3
    assert "screenshot" not in newest  # no blob field, not even base64

    oldest = body["items"][1]
    assert oldest["has_screenshot"] is False
    assert oldest["screenshot_size"] is None


async def test_admin_gate_wrong_key_rejected_401(client):
    await client.post("/api/v1/feedback", headers=_bearer(), data={"message": "x"})
    resp = await client.get("/api/v1/feedback", headers={"X-Admin-Key": "wrong"})
    assert resp.status_code == 401


async def test_admin_gate_missing_key_rejected(client):
    """No `X-Admin-Key` header at all fails FastAPI's own required-header
    validation (422) before `verify_admin_key`'s body ever runs — same shape
    as every other route already gated by it (#91)."""
    resp = await client.get("/api/v1/feedback")
    assert resp.status_code == 422


async def test_detail_unknown_id_404(client):
    resp = await client.get(
        "/api/v1/feedback/00000000-0000-0000-0000-000000000000",
        headers={"X-Admin-Key": _ADMIN_KEY},
    )
    assert resp.status_code == 404
