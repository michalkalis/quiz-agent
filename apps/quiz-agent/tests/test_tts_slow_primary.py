"""A slow (not failed) primary voice hands over to the backup in time (#235).

Why this matters to a player: the app stops waiting for question audio after
10 s. When ElevenLabs was slow rather than down, the server waited its full
30 s HTTP timeout before trying the backup voice, so the question was never
read out at all. The primary now gets ``PRIMARY_TTS_TIMEOUT_S``; after that the
backup speaks, while the behaviours around it stay as they were: one shared
synthesis per text, a departing waiter does not cancel it, audio is cached
under the voice that spoke, and only delivered primary audio is billed.

The limit is shrunk to milliseconds and the slow provider simply never answers,
so the tests prove the bound without sleeping for it.
"""

import asyncio
import logging

import pytest
from app.tts import service as service_module
from app.tts.providers import PRIMARY_TTS_TIMEOUT_S
from app.tts.service import TTSBilling, TTSService

pytestmark = pytest.mark.asyncio

# Generous guard so a broken bound fails the test instead of hanging it.
GUARD_S = 1.0


class HangingProvider:
    """Accepts the request and never answers: slow, not down."""

    def __init__(self, name="elevenlabs", voice="george-id"):
        self.name, self.default_voice = name, voice
        self.calls: list[str] = []
        self.cancelled = 0
        self.release = asyncio.Event()

    async def synthesize(self, text, voice):
        self.calls.append(text)
        try:
            await self.release.wait()
        except asyncio.CancelledError:
            self.cancelled += 1
            raise
        return f"{self.name}-audio".encode()


class FastProvider:
    def __init__(self, name="openai", voice="nova"):
        self.name, self.default_voice = name, voice
        self.calls: list[str] = []

    async def synthesize(self, text, voice):
        self.calls.append(text)
        return f"{self.name}-audio".encode()


@pytest.fixture(autouse=True)
def _short_limit(tmp_path, monkeypatch):
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "tts_cache"))
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.setattr(service_module, "PRIMARY_TTS_TIMEOUT_S", 0.01)


def test_limit_leaves_the_backup_room_inside_the_apps_wait():
    """The app gives up on question audio at 10 s; the founder-approved range
    for the primary's share is 6–8 s, and the backup needs the rest."""
    assert 6.0 <= PRIMARY_TTS_TIMEOUT_S <= 8.0


async def test_slow_primary_hands_over_to_the_backup_within_the_limit(caplog):
    primary, backup = HangingProvider(), FastProvider()
    service = TTSService(provider=primary, fallback_provider=backup)
    billing = TTSBilling()

    with caplog.at_level(logging.WARNING, logger="app.tts.service"):
        audio = await asyncio.wait_for(
            service.synthesize("Question one?", billing=billing), GUARD_S
        )

    assert audio == b"openai-audio"
    assert primary.calls == backup.calls == ["Question one?"]
    # The player got the backup voice, so their ElevenLabs budget is not charged.
    assert billing.billed_chars == 0
    # Triage must see that the primary was slow, not that it refused.
    assert "elevenlabs failed, falling back to openai: no audio within" in caplog.text


async def test_cut_off_attempt_is_stopped_and_caches_only_the_backup():
    """The abandoned primary call is cancelled (no hidden work holding a
    synthesis slot) and the backup clip is cached under its own voice, so the
    next request still tries George first."""
    primary, backup = HangingProvider(), FastProvider()
    service = TTSService(provider=primary, fallback_provider=backup)

    await asyncio.wait_for(service.synthesize("Question one?"), GUARD_S)

    assert primary.cancelled == 1
    assert service.cache.get("Question one?", "nova") == b"openai-audio"
    assert service.cache.get("Question one?", "george-id") is None


async def test_waiters_on_one_slow_synthesis_all_get_the_backup_once():
    """Prefetch and the app's own fetch share one synthesis; one of them
    hanging up must not cancel it for the other."""
    primary, backup = HangingProvider(), FastProvider()
    service = TTSService(provider=primary, fallback_provider=backup)

    leader = asyncio.create_task(service.synthesize("Question one?"))
    follower = asyncio.create_task(service.synthesize("Question one?"))
    await asyncio.sleep(0)
    leader.cancel()

    assert await asyncio.wait_for(follower, GUARD_S) == b"openai-audio"
    assert primary.calls == backup.calls == ["Question one?"]
    assert service._in_flight == {}


async def test_healthy_primary_is_untouched_by_the_limit(monkeypatch):
    """The normal path: George speaks, is cached and billed, the backup idles."""
    primary, backup = FastProvider("elevenlabs", "george-id"), FastProvider()
    service = TTSService(provider=primary, fallback_provider=backup)
    monkeypatch.setattr(service_module, "PRIMARY_TTS_TIMEOUT_S", GUARD_S)
    billing = TTSBilling()

    assert await service.synthesize("Question one?", billing=billing) == (
        b"elevenlabs-audio"
    )
    assert backup.calls == []
    assert billing.billed_chars == len("Question one?")
    assert service.cache.get("Question one?", "george-id") == b"elevenlabs-audio"


async def test_without_a_backup_a_slow_primary_is_still_awaited():
    """Cutting the only voice off would turn late audio into no audio."""
    primary = HangingProvider()
    service = TTSService(provider=primary)
    service.fallback = None

    async def answer_late():
        await asyncio.sleep(0.03)  # past the 10 ms limit
        primary.release.set()

    releaser = asyncio.create_task(answer_late())
    audio = await asyncio.wait_for(service.synthesize("Question one?"), GUARD_S)
    await releaser

    assert audio == b"elevenlabs-audio"
    assert primary.cancelled == 0
