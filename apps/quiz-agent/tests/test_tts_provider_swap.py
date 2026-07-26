"""TTS backend selection and failover (founder call 2026-07-26).

Why this matters: the quiz voice moved from OpenAI TTS to ElevenLabs (George),
but OpenAI was deliberately kept wired up as a live backup rather than deleted,
on the explicit condition that swapping the two stays a config change. Two
things can therefore break silently and are pinned here:

1. The swap. If `TTS_PROVIDER` stops selecting the backend — or flipping it
   leaves a deploy with no backup — the "keep the old one as backup" decision
   is dead and nobody finds out until the voice is gone.
2. The failover. ElevenLabs bills reading questions and transcribing answers
   from ONE shared credit budget, so hitting the quota wall mid-drive is a
   realistic failure. It must degrade to the other voice, never to silence.

The provider-namespaced static cache is pinned for the same reason: without it
a swapped provider replays the previous vendor's voice out of a warm cache, so
the swap appears to do nothing.
"""

import pytest

from app.tts.cache import TTSCache
from app.tts.service import TTSService
from app.tts.voices import ELEVENLABS_VOICES

pytestmark = pytest.mark.asyncio


class FakeProvider:
    """Records calls so a test can prove which backend actually spoke."""

    def __init__(self, name: str, voice: str, audio: bytes = b"", fails: bool = False):
        self.name = name
        self.default_voice = voice
        self._audio = audio or f"{name}-audio".encode()
        self._fails = fails
        self.calls: list[tuple[str, str]] = []

    async def synthesize(self, text: str, voice: str) -> bytes:
        self.calls.append((text, voice))
        if self._fails:
            raise RuntimeError(f"{self.name} quota exhausted")
        return self._audio


@pytest.fixture(autouse=True)
def _isolated_config(tmp_path, monkeypatch):
    """Keep every test off the real cache dir and off inherited env config."""
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "tts_cache"))
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.delenv("TTS_PROVIDER", raising=False)
    monkeypatch.delenv("TTS_FALLBACK_PROVIDER", raising=False)
    monkeypatch.delenv("TTS_VOICE", raising=False)


class TestBackendSelection:
    async def test_default_is_elevenlabs_george_with_openai_backup(self):
        """The shipped default IS the founder's decision — assert it explicitly."""
        service = TTSService()

        assert service.provider.name == "elevenlabs"
        assert service.provider.default_voice == ELEVENLABS_VOICES["george"]
        assert service.fallback.name == "openai"

    async def test_flipping_the_provider_swaps_both_roles(self, monkeypatch):
        """One env var must move the old engine back into the driving seat.

        The backup has to follow it the other way: a deploy that swaps to
        OpenAI and silently ends up with no fallback is the failure this whole
        arrangement exists to prevent.
        """
        monkeypatch.setenv("TTS_PROVIDER", "openai")
        service = TTSService()

        assert service.provider.name == "openai"
        assert service.fallback.name == "elevenlabs"

    async def test_fallback_can_be_switched_off(self, monkeypatch):
        monkeypatch.setenv("TTS_FALLBACK_PROVIDER", "none")
        assert TTSService().fallback is None

    async def test_voice_override_applies_to_primary_only(self, monkeypatch):
        """A voice override is vendor-specific, so it must not poison the backup.

        An ElevenLabs voice id handed to OpenAI would make the fallback fail on
        exactly the request it was supposed to rescue.
        """
        monkeypatch.setenv("TTS_VOICE", ELEVENLABS_VOICES["alice"])
        service = TTSService()

        assert service.provider.default_voice == ELEVENLABS_VOICES["alice"]
        assert service.fallback.default_voice == "nova"

    async def test_unknown_provider_fails_loudly(self, monkeypatch):
        monkeypatch.setenv("TTS_PROVIDER", "coqui")
        with pytest.raises(ValueError, match="Unknown TTS provider"):
            TTSService()


class TestFailover:
    async def test_quota_wall_on_primary_degrades_to_backup_audio(self):
        """A dead ElevenLabs budget must cost the user voice quality, not the question."""
        primary = FakeProvider("elevenlabs", "george-id", fails=True)
        backup = FakeProvider("openai", "nova", audio=b"backup-audio")
        service = TTSService(provider=primary, fallback_provider=backup)

        assert await service.synthesize("Which two continents?") == b"backup-audio"
        assert backup.calls == [("Which two continents?", "nova")]

    async def test_backup_is_not_called_while_primary_works(self):
        primary = FakeProvider("elevenlabs", "george-id", audio=b"george-audio")
        backup = FakeProvider("openai", "nova")
        service = TTSService(provider=primary, fallback_provider=backup)

        assert await service.synthesize("Question one.") == b"george-audio"
        assert backup.calls == []

    async def test_both_backends_down_names_both_causes(self):
        """The error has to say which two vendors failed, or triage starts blind."""
        primary = FakeProvider("elevenlabs", "george-id", fails=True)
        backup = FakeProvider("openai", "nova", fails=True)
        service = TTSService(provider=primary, fallback_provider=backup)

        with pytest.raises(RuntimeError) as exc:
            await service.synthesize("Question one.")

        assert "elevenlabs" in str(exc.value) and "openai" in str(exc.value)

    async def test_no_backup_configured_surfaces_the_primary_error(self):
        primary = FakeProvider("elevenlabs", "george-id", fails=True)
        service = TTSService(provider=primary, fallback_provider=None)
        service.fallback = None

        with pytest.raises(RuntimeError, match="quota exhausted"):
            await service.synthesize("Question one.")

    async def test_fallback_audio_is_cached_under_its_own_voice(self):
        """Primary and backup audio must coexist, so recovery does not evict George.

        They share one cache keyed by (text, voice); if the fallback wrote under
        the primary's key, the next successful ElevenLabs call would serve the
        OpenAI clip instead.
        """
        primary = FakeProvider("elevenlabs", "george-id", fails=True)
        backup = FakeProvider("openai", "nova", audio=b"backup-audio")
        service = TTSService(provider=primary, fallback_provider=backup)

        await service.synthesize("Question one.")

        assert service.cache.get("Question one.", "nova") == b"backup-audio"
        assert service.cache.get("Question one.", "george-id") is None


class TestStaticFeedbackNamespace:
    async def test_switching_provider_does_not_replay_the_old_voice(self, tmp_path):
        """Pre-generated praise clips are keyed by filename, not by voice.

        Without a provider namespace the warm cache would keep answering
        "Nailed it!" in the previous vendor's voice after a swap, mid-quiz,
        while questions came back in the new one.
        """
        cache_dir = str(tmp_path / "shared_cache")
        openai_cache = TTSCache(cache_dir=cache_dir, provider="openai")
        openai_cache.set_static_feedback("correct", 0, b"nova-nailed-it")

        elevenlabs_cache = TTSCache(cache_dir=cache_dir, provider="elevenlabs")

        assert elevenlabs_cache.get_static_feedback("correct", 0) is None
        assert openai_cache.get_static_feedback("correct", 0) == b"nova-nailed-it"
