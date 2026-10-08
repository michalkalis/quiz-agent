"""Per-user daily budget on POST /tts/synthesize (#193 task 193.13).

Why it matters: the endpoint speaks any client text through ElevenLabs, whose
Starter plan (30k chars/month) is shared with speech-to-text. One signed-in
user looping on it would drain credits for every beta tester. The cap must
(a) degrade the voice to the OpenAI fallback rather than fail, (b) bill only
real ElevenLabs spend (cache hits are free), and (c) never leak across users.
"""

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.api.routes import tts as tts_routes
from app.auth.tokens import TokenService
from app.rate_limit import limiter
from app.tts.service import TTSService
from app.usage.tracker import UsageTracker

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64
BUDGET = 100


class FakeProvider:
    def __init__(self, name, voice):
        self.name, self.default_voice = name, voice
        self.calls = []

    async def synthesize(self, text, voice):
        self.calls.append(text)
        return f"{self.name}-audio".encode()


class FakeTracker:
    """In-memory stand-in for the two UsageTracker TTS methods."""

    def __init__(self):
        self.chars = {}

    async def tts_chars_today(self, subject_id):
        return self.chars.get(subject_id, 0)

    async def add_tts_chars(self, subject_id, chars):
        self.chars[subject_id] = self.chars.get(subject_id, 0) + chars


def _bearer(subject):
    ts = TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )
    return {"Authorization": f"Bearer {ts.create_access_token(subject)}"}


@pytest_asyncio.fixture
async def env(tmp_path, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    monkeypatch.setenv("TTS_SYNTHESIZE_DAILY_CHAR_BUDGET", str(BUDGET))

    limiter.reset()
    primary, fallback = (
        FakeProvider("elevenlabs", "v-el"),
        FakeProvider("openai", "nova"),
    )
    service = TTSService(provider=primary, fallback_provider=fallback)
    tracker = FakeTracker()
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(tts_routes.router, prefix="/api/v1")
    app.state.token_service = TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )
    app.state.tts_service = service
    app.state.usage_tracker = tracker
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        yield client, primary, fallback, tracker, service


async def _say(client, user, text):
    return await client.post(
        "/api/v1/tts/synthesize", json={"text": text}, headers=_bearer(user)
    )


async def test_over_budget_falls_back_instead_of_failing(env):
    """Once a user spends the budget the voice degrades (OpenAI), the call still
    succeeds, and ElevenLabs is no longer touched for that user."""
    client, primary, fallback, tracker, _ = env
    assert (await _say(client, "u1", "a" * BUDGET)).content == b"elevenlabs-audio"
    resp = await _say(client, "u1", "second line")
    assert resp.status_code == 200
    assert resp.content == b"openai-audio"
    assert primary.calls == ["a" * BUDGET]
    assert tracker.chars["u1"] == BUDGET  # fallback audio is not billed


async def test_cache_hits_are_free_and_uncounted(env):
    """Replaying identical text is served from cache: no provider call and no
    budget spent, so repeated legit prompts can never exhaust the cap."""
    client, primary, _, tracker, _ = env
    for _i in range(5):
        assert (await _say(client, "u1", "Say it again")).status_code == 200
    assert len(primary.calls) == 1
    assert tracker.chars["u1"] == len("Say it again")


async def test_over_budget_user_still_gets_cached_primary_audio(env):
    """Cached ElevenLabs audio costs nothing, so a capped user keeps the good
    voice for text someone already paid for."""
    client, _, fallback, tracker, _ = env
    await _say(client, "u2", "Shared prompt")
    tracker.chars["u1"] = BUDGET  # u1 is capped
    resp = await _say(client, "u1", "Shared prompt")
    assert resp.content == b"elevenlabs-audio"
    assert fallback.calls == []


async def test_budget_is_per_user(env):
    """One user exhausting the budget must not degrade anyone else."""
    client, _, _, tracker, _ = env
    tracker.chars["abuser"] = BUDGET
    assert (await _say(client, "abuser", "hello")).content == b"openai-audio"
    assert (await _say(client, "friend", "hello again")).content == b"elevenlabs-audio"


async def test_over_budget_without_fallback_is_429(env):
    """With no backup voice the only way to protect credits is a clean 429
    (iOS treats any failed synth as 'no spoken audio' and carries on)."""
    client, _, _, tracker, service = env
    service.fallback = None
    tracker.chars["u1"] = BUDGET
    resp = await _say(client, "u1", "anything")
    assert resp.status_code == 429
    assert resp.headers["retry-after"]


async def test_tracker_counts_per_subject_per_day(db_sessionmaker):
    """The counter is the durable half: it accumulates and is isolated per subject."""
    t = UsageTracker(db_sessionmaker)
    await t.add_tts_chars("a", 40)
    await t.add_tts_chars("a", 2)
    assert await t.tts_chars_today("a") == 42
    assert await t.tts_chars_today("b") == 0
