"""POST /api/v1/voice-samples — car answer recordings for replay tests (#197).

WHY these matter: the endpoint stores raw voice recordings. It exists for the
founder's own replay corpus only, so the contract is (1) nobody outside the
``VOICE_SAMPLE_UPLOAD_USER_IDS`` allowlist can store anything — not an
unauthenticated grace caller, not a valid bearer of another user; (2) only a
real WAV under the size cap is accepted, so the bucket can't be used as free
file hosting; (3) a retried upload (lost response, app restart) never stores
the same recording twice, otherwise the replay accuracy would double-count it.

No Postgres needed: an in-memory sessionmaker stands in for the table and a
fake storage for R2, so these run on every machine.
"""

from __future__ import annotations

import json
import struct
import uuid
from datetime import datetime, timezone

import pytest
import pytest_asyncio
from app.api.routes import voice_samples as routes
from app.auth.tokens import TokenService
from app.db.models import VoiceSample
from app.rate_limit import limiter
from app.voice.sample_storage import R2VoiceSampleStorage
from sqlalchemy.exc import IntegrityError
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

pytestmark = pytest.mark.asyncio

_SECRET = "v" * 64
_FOUNDER = "founder-subject"


def _tokens() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _bearer(subject: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {_tokens().create_access_token(subject)}"}


def _wav(pcm_bytes: int = 3200) -> bytes:
    header = b"RIFF" + struct.pack("<I", 36 + pcm_bytes) + b"WAVE" + b"\0" * 32
    return header + b"\x01" * pcm_bytes


class _Result:
    def __init__(self, value):
        self._value = value

    def scalar_one_or_none(self):
        return self._value

    def scalars(self):
        return self

    def all(self):
        return self._value


class _FakeDB:
    """Just enough of an AsyncSession for the route: a key lookup and a
    transactional insert (``rows`` = committed; uncommitted rows vanish when
    the session closes, like a rollback)."""

    def __init__(self) -> None:
        self.rows: list[VoiceSample] = []
        self.pending: list[VoiceSample] = []
        self.fail_commit = False
        self.concurrent_winner: VoiceSample | None = None

    def __call__(self):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        self.pending = []
        return False

    async def flush(self):
        if self.concurrent_winner is not None:
            # Another request committed the same r2_key between our check and insert.
            self.rows.append(self.concurrent_winner)
            self.concurrent_winner = None
            raise IntegrityError("INSERT", {}, Exception("duplicate r2_key"))

    async def rollback(self):
        self.pending = []

    async def execute(self, stmt):
        if stmt.whereclause is None:  # the admin list
            for row in self.rows:
                row.created_at = row.created_at or datetime.now(timezone.utc)
            return _Result(list(self.rows))
        key = stmt.whereclause.right.value
        match = next((r.id for r in self.rows if r.r2_key == key), None)
        return _Result(match)

    def add(self, row):
        self.pending.append(row)

    async def commit(self):
        if self.fail_commit:
            raise OSError("connection reset during commit")
        self.rows.extend(self.pending)
        self.pending = []


class _FakeStorage:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    def put(self, key, data, content_type):
        self.objects[key] = data

    def delete(self, keys):
        for key in keys:
            self.objects.pop(key, None)

    def presigned_url(self, key, expires_seconds=3600):
        return f"https://r2.test/{key}"


@pytest_asyncio.fixture
async def env(monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    monkeypatch.setenv(routes.ALLOWLIST_ENV, f" {_FOUNDER} , someone-else ")
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(routes.router, prefix="/api/v1")
    app.state.token_service = _tokens()
    db, storage = _FakeDB(), _FakeStorage()
    app.state.auth_sessionmaker = db
    app.state.voice_sample_storage = storage
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        yield client, db, storage


def _post(
    client,
    headers,
    *,
    audio=None,
    content_type="audio/wav",
    sidecar=None,
    stamp="20261010-101500-123",
):
    return client.post(
        "/api/v1/voice-samples",
        headers=headers,
        data={
            "stamp": stamp,
            "sidecar": json.dumps(
                sidecar
                if sidecar is not None
                else {
                    "language": "sk",
                    "sessionId": "s1",
                    "questionId": "q1",
                    "appDecision": "correct",
                }
            ),
        },
        files={
            "audio": (
                "answer.wav",
                audio if audio is not None else _wav(),
                content_type,
            )
        },
    )


async def test_allowlisted_founder_upload_is_stored_with_its_metadata(env):
    client, db, storage = env
    resp = await _post(client, _bearer(_FOUNDER))
    assert resp.status_code == 201, resp.text
    assert len(db.rows) == 1 and len(storage.objects) == 1
    row = db.rows[0]
    # The replay script filters and joins on these — they must come from the sidecar.
    assert (row.user_id, row.session_id, row.question_id, row.language) == (
        _FOUNDER,
        "s1",
        "q1",
        "sk",
    )
    assert row.sidecar["appDecision"] == "correct"
    assert row.label is None
    assert row.r2_key in storage.objects
    assert _FOUNDER not in row.r2_key, "bucket keys must not carry the subject id"


async def test_valid_bearer_outside_the_allowlist_is_refused(env):
    client, db, storage = env
    resp = await _post(client, _bearer("random-player"))
    assert resp.status_code == 403
    assert db.rows == [] and storage.objects == {}


async def test_grace_caller_without_bearer_is_refused_even_with_grace_on(env):
    client, _db, storage = env
    resp = await _post(client, {})
    assert resp.status_code == 403
    assert storage.objects == {}


async def test_empty_allowlist_refuses_everyone(env, monkeypatch):
    client, _db, _storage = env
    monkeypatch.setenv(routes.ALLOWLIST_ENV, "")
    resp = await _post(client, _bearer(_FOUNDER))
    assert resp.status_code == 403


async def test_oversized_audio_is_rejected_before_storage(env, monkeypatch):
    client, _db, storage = env
    monkeypatch.setattr(routes, "AUDIO_MAX_BYTES", 4000)
    resp = await _post(client, _bearer(_FOUNDER), audio=_wav(8000))
    assert resp.status_code == 413
    assert storage.objects == {}


@pytest.mark.parametrize(
    "audio,content_type",
    [
        (b"ID3" + b"\0" * 5000, "audio/wav"),  # an MP3 posing as WAV
        (_wav(), "audio/mpeg"),  # declared as something else
        (_wav(), "application/octet-stream"),
    ],
)
async def test_non_wav_is_rejected(env, audio, content_type):
    client, _db, storage = env
    resp = await _post(
        client, _bearer(_FOUNDER), audio=audio, content_type=content_type
    )
    assert resp.status_code == 415
    assert storage.objects == {}


async def test_malformed_sidecar_or_stamp_is_rejected(env):
    client, _db, storage = env
    bad_json = await client.post(
        "/api/v1/voice-samples",
        headers=_bearer(_FOUNDER),
        data={"stamp": "20261010-101500-123", "sidecar": "not json"},
        files={"audio": ("a.wav", _wav(), "audio/wav")},
    )
    assert bad_json.status_code == 400
    # A stamp feeds the object key — a path-ish value must never get through.
    bad_stamp = await _post(client, _bearer(_FOUNDER), stamp="../../etc")
    assert bad_stamp.status_code == 400
    assert storage.objects == {}


async def test_retried_upload_is_a_duplicate_not_a_second_sample(env):
    """The app deletes its local copy only after a 2xx; if that response was
    lost it uploads again on next start. That retry must not double-count."""
    client, db, _storage = env
    first = await _post(client, _bearer(_FOUNDER))
    second = await _post(client, _bearer(_FOUNDER))
    assert first.status_code == 201
    assert second.status_code == 201
    assert second.json() == {"id": first.json()["id"], "duplicate": True}
    assert len(db.rows) == 1


async def test_missing_r2_config_fails_loud_at_call_time(env, monkeypatch):
    client, db, _ = env
    for name in (
        "R2_ENDPOINT",
        "R2_ACCESS_KEY_ID",
        "R2_SECRET_ACCESS_KEY",
        "VOICE_SAMPLES_R2_BUCKET",
    ):
        monkeypatch.delenv(name, raising=False)
    client._transport.app.state.voice_sample_storage = R2VoiceSampleStorage()
    resp = await _post(client, _bearer(_FOUNDER))
    assert resp.status_code == 503
    assert "not configured" in resp.json()["detail"]
    assert db.rows == [], "no row may point at audio that was never stored"


async def test_admin_list_hands_out_presigned_audio_only_with_the_admin_key(
    env, monkeypatch
):
    """The replay script pulls the corpus through this list; the audio is in a
    private bucket, so the only way out is a short-lived presigned URL behind
    the admin key."""
    client, _db, _ = env
    monkeypatch.setenv("ADMIN_API_KEY", "admin-key")
    await _post(client, _bearer(_FOUNDER))

    denied = await client.get("/api/v1/voice-samples", headers={"X-Admin-Key": "wrong"})
    assert denied.status_code == 401

    resp = await client.get(
        "/api/v1/voice-samples", headers={"X-Admin-Key": "admin-key"}
    )
    assert resp.status_code == 200
    item = resp.json()["items"][0]
    assert item["audio_url"].startswith("https://r2.test/voice-samples/")
    assert item["sidecar"]["appDecision"] == "correct"
    assert item["label"] is None


# ── security review fixes ───────────────────────────────────────────────────


async def test_oversized_body_is_refused_from_headers_before_auth_or_parsing(env):
    """FastAPI parses multipart (to temp disk) before any dependency, so an
    anonymous caller could otherwise stream gigabytes. The declared length is
    checked first — no bearer, no body read, 413."""
    client, db, storage = env
    resp = await client.post(
        "/api/v1/voice-samples",
        content=b"x",
        headers={
            "Content-Length": str(routes.BODY_MAX_BYTES + 1),
            "Content-Type": "multipart/form-data; boundary=b",
        },
    )
    assert resp.status_code == 413
    assert storage.objects == {}


async def test_body_without_declared_length_is_refused(env):
    """A chunked body has no length to check up front — refuse it (411)."""
    client, _db, _ = env

    async def chunks():
        yield b"--b\r\n"

    resp = await client.post(
        "/api/v1/voice-samples",
        content=chunks(),
        headers={"Content-Type": "multipart/form-data; boundary=b"},
    )
    assert resp.status_code == 411


async def test_failed_commit_removes_the_audio_so_nothing_is_orphaned(env):
    """A WAV in R2 without its row is invisible to account erasure — if the
    row can't be committed, the object must go too."""
    client, db, storage = env
    db.fail_commit = True
    resp = await _post(client, _bearer(_FOUNDER))
    assert resp.status_code == 503
    assert db.rows == []
    assert storage.objects == {}, "R2 object left without a DB row"


async def test_concurrent_duplicate_is_answered_as_duplicate_not_500(env):
    """Two retries of one recording can pass the existence check together; the
    loser hits the unique r2_key and must get the winner's id, so the app
    deletes its local copy instead of retrying forever."""
    client, db, _ = env
    winner = VoiceSample(
        id=uuid.uuid4(), r2_key=routes.sample_key(_FOUNDER, "20261010-101500-123")
    )
    db.concurrent_winner = winner
    resp = await _post(client, _bearer(_FOUNDER))
    assert resp.status_code == 201
    assert resp.json() == {"id": str(winner.id), "duplicate": True}
    assert db.rows == [winner]
