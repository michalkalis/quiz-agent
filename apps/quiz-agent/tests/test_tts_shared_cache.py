"""TTS audio shared through R2 across machines (#207.20, design step 4).

Why: ElevenLabs credits are scarce (Starter plan, no top-up; ~185 credits per
first read of a question). Without the volume, every new machine (deploy,
second machine, host move) would start with an empty disk cache and buy every
question again. So:
- a fresh machine must serve audio another machine already bought with zero
  provider calls;
- the same question requested on two machines at once (the serve-time
  prefetch and the client's own fetch often land on different machines) must
  be synthesized once;
- an R2 outage must never silence a question (it only costs a synthesis).
"""

from __future__ import annotations

import asyncio

import pytest
from app.coordination.leases import LeaseStore
from app.tts.service import TTSService

pytestmark = pytest.mark.asyncio


class CountingProvider:
    name = "counting"
    default_voice = "voice-a"

    def __init__(self, delay: float = 0.0) -> None:
        self.calls: list[str] = []
        self.delay = delay

    async def synthesize(self, text: str, voice: str) -> bytes:
        self.calls.append(text)
        await asyncio.sleep(self.delay)
        return b"ID3audio-" + text.encode()


class FakeR2:
    """In-memory stand-in for the bucket both machines share."""

    def __init__(self, broken: bool = False) -> None:
        self.objects: dict[str, bytes] = {}
        self.broken = broken

    async def get(self, key: str):
        return None if self.broken else self.objects.get(key)

    async def put(self, key: str, data: bytes) -> None:
        if not self.broken:
            self.objects[key] = data


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("TTS_FALLBACK_PROVIDER", "none")
    monkeypatch.setattr("app.tts.service.boost_volume", lambda audio: audio)


def _machine(tmp_path, name, r2, provider, leases=None) -> TTSService:
    service = TTSService(provider=provider, cache_dir=str(tmp_path / name))
    service.remote = r2
    service.leases = leases
    return service


async def test_fresh_machine_serves_cached_audio_without_paying_again(tmp_path):
    r2 = FakeR2()
    first = CountingProvider()
    a = _machine(tmp_path, "a", r2, first)
    await a.synthesize_question("Ktoré mesto je hlavné?")

    second = CountingProvider()
    b = _machine(tmp_path, "b", r2, second)  # empty disk: new machine
    audio = await b.synthesize_question("Ktoré mesto je hlavné?")
    assert audio == "ID3audio-Ktoré mesto je hlavné?".encode()
    assert second.calls == []


async def test_static_feedback_is_not_regenerated_on_a_new_machine(tmp_path):
    r2 = FakeR2()
    first = CountingProvider()
    await _machine(tmp_path, "a", r2, first).pregenerate_static_feedback()
    assert first.calls  # paid once
    second = CountingProvider()
    b = _machine(tmp_path, "b", r2, second)
    await b.pregenerate_static_feedback()
    assert second.calls == []
    assert await b.get_feedback_audio("correct", variant=0)


async def test_same_question_on_two_machines_at_once_is_synthesized_once(
    tmp_path, db_sessionmaker
):
    r2 = FakeR2()
    pa, pb = CountingProvider(delay=0.3), CountingProvider(delay=0.3)
    a = _machine(tmp_path, "a", r2, pa, LeaseStore(db_sessionmaker))
    b = _machine(tmp_path, "b", r2, pb, LeaseStore(db_sessionmaker))
    one, two = await asyncio.gather(
        a.synthesize_question("Koľko nôh má pavúk?"),
        b.synthesize_question("Koľko nôh má pavúk?"),
    )
    assert one == two
    assert len(pa.calls) + len(pb.calls) == 1


async def test_r2_outage_still_speaks_the_question(tmp_path):
    provider = CountingProvider()
    a = _machine(tmp_path, "a", FakeR2(broken=True), provider)
    assert await a.synthesize_question("Otázka?") == "ID3audio-Otázka?".encode()
    assert provider.calls == ["Otázka?"]
