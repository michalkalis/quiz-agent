"""Account deletion and export cover car answer recordings (#197 on top of #193).

WHY: a voice recording is the most personal thing the app stores, and it lives
in two places — a ``voice_samples`` row and an object in a private R2 bucket.
GDPR erasure must remove BOTH for the account and for every anon id linked to
it (sign-in does not re-key them), and must never commit a "deleted" account
while its audio is still in the bucket. If R2 refuses, the whole erasure rolls
back and answers 503, so the person retries and nothing is half-deleted
silently. The export lists the recordings (with the audio described, not
embedded) so the person can see what exists.

The first group needs no Postgres (fake session); the route tests run on the
test Postgres in CI (``REQUIRE_DB_TESTS=1``) and skip locally without it.
"""

from __future__ import annotations

import pytest
from app.db.models import Feedback, VoiceSample
from app.voice.sample_erasure import VoiceSampleErasureFailed, erase_voice_samples

from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _rows,
    _seed_anon_upgraded,
    _user_exists,
)
from tests.test_auth_me_erase_anon_trail import _make_anon
from tests.test_auth_me_erase_unlinks import _delete

pytestmark = pytest.mark.asyncio

OTHER = "someone-else"


class FakeStorage:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.deleted: list[str] = []

    def delete(self, keys):
        if self.fail:
            raise RuntimeError("R2 down")
        self.deleted.extend(keys)


# ── erase_voice_samples, no DB ──────────────────────────────────────────────


class _Scalars:
    def __init__(self, values):
        self._values = values

    def scalars(self):
        return self

    def all(self):
        return self._values


class FakeSession:
    def __init__(self, keys):
        self.keys = keys
        self.deletes = 0

    async def execute(self, stmt):
        if stmt.is_select:
            return _Scalars(list(self.keys))
        self.deletes += 1
        return None


async def test_rows_are_dropped_only_after_r2_deleted_the_audio():
    session, storage = FakeSession(["k1", "k2"]), FakeStorage()
    assert await erase_voice_samples(session, ["u"], storage) == 2
    assert storage.deleted == ["k1", "k2"]
    assert session.deletes == 1


async def test_r2_failure_raises_and_keeps_the_rows():
    """Dropping the rows while the audio stays would leave recordings nobody
    can find or erase again — the failure must surface, not be swallowed."""
    session = FakeSession(["k1"])
    with pytest.raises(VoiceSampleErasureFailed):
        await erase_voice_samples(session, ["u"], FakeStorage(fail=True))
    assert session.deletes == 0


async def test_no_recordings_never_touches_r2():
    """Almost nobody has recordings; their erasure must not depend on R2 being
    configured or up."""
    storage = FakeStorage(fail=True)
    assert await erase_voice_samples(FakeSession([]), ["u"], storage) == 0


# ── DELETE /auth/me and export, test Postgres ───────────────────────────────


async def _seed_sample(db, user_id: str, key: str) -> None:
    async with db() as s:
        s.add(
            VoiceSample(
                user_id=user_id,
                sidecar={"transcript": "Jupiter", "appDecision": "correct"},
                r2_key=key,
                audio_bytes=3244,
                language="sk",
            )
        )
        await s.commit()


async def test_account_delete_erases_recordings_from_before_and_after_sign_in(
    db_sessionmaker,
):
    app = _make_app(db_sessionmaker)
    storage = FakeStorage()
    app.state.voice_sample_storage = storage
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.voice")
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    await _seed_sample(db_sessionmaker, user_id, "voice-samples/u/1.wav")
    await _seed_sample(db_sessionmaker, anon_id, "voice-samples/a/2.wav")
    await _seed_sample(db_sessionmaker, OTHER, "voice-samples/o/3.wav")

    assert (await _delete(app, bearer)).status_code == 204

    assert sorted(storage.deleted) == ["voice-samples/a/2.wav", "voice-samples/u/1.wav"]
    remaining = await _rows(db_sessionmaker, VoiceSample)
    assert [r.user_id for r in remaining] == [OTHER]


async def test_anonymous_delete_erases_its_recordings(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    storage = FakeStorage()
    app.state.voice_sample_storage = storage
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _seed_sample(db_sessionmaker, anon_id, "voice-samples/a/1.wav")

    assert (await _delete(app, bearer)).status_code == 204

    assert storage.deleted == ["voice-samples/a/1.wav"]
    assert await _rows(db_sessionmaker, VoiceSample) == []


async def test_r2_outage_rolls_the_whole_erasure_back_with_503(db_sessionmaker):
    """Nothing may be reported deleted while audio remains: the account, its
    feedback and its recording rows all stay, so the retry finds them again."""
    app = _make_app(db_sessionmaker)
    app.state.voice_sample_storage = FakeStorage(fail=True)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.voice2")
    await _seed_sample(db_sessionmaker, user_id, "voice-samples/u/1.wav")
    async with db_sessionmaker() as s:
        s.add(Feedback(user_id=user_id, message="keep until retried"))
        await s.commit()

    resp = await _delete(app, bearer)

    assert resp.status_code == 503
    assert await _user_exists(db_sessionmaker, user_id)
    assert len(await _rows(db_sessionmaker, VoiceSample)) == 1
    assert len(await _rows(db_sessionmaker, Feedback)) == 1

    app.state.voice_sample_storage = FakeStorage()
    assert (await _delete(app, bearer)).status_code == 204
    assert await _rows(db_sessionmaker, VoiceSample) == []


async def test_export_lists_recordings_with_the_audio_described_not_embedded(
    db_sessionmaker,
):
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.voice3")
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    await _seed_sample(db_sessionmaker, anon_id, "voice-samples/a/1.wav")
    await _seed_sample(db_sessionmaker, OTHER, "voice-samples/o/2.wav")

    async with _asgi(app) as c:
        resp = await c.get("/api/v1/auth/me/export", headers=_auth(bearer))

    assert resp.status_code == 200, resp.text
    samples = resp.json()["voice_samples"]
    assert len(samples) == 1, "pre-sign-in recording shows up once; nobody else's"
    assert samples[0]["sidecar"]["transcript"] == "Jupiter"
    assert samples[0]["audio"] == {"content_type": "audio/wav", "bytes": 3244}
    assert "r2_key" not in samples[0] and "audio_url" not in samples[0]
