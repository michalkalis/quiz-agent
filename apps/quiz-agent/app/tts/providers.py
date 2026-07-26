"""Pluggable TTS synthesis backends (ElevenLabs / OpenAI).

Founder call 2026-07-26: ElevenLabs becomes the primary voice (George reads
both English and Slovak well), with the incumbent OpenAI TTS kept as a live
backup rather than deleted — so the two must be swappable by config, not by
code change. `TTS_PROVIDER` picks the primary; `TTS_FALLBACK_PROVIDER` picks
who covers a synthesis failure (quota exhausted, upstream 5xx). Caching,
volume boost and the static-feedback tier stay in `TTSService`, which is
provider-agnostic — a provider here only turns text into MP3 bytes.
"""

from __future__ import annotations

import logging
import os
from typing import Optional, Protocol, runtime_checkable

import httpx

from quiz_shared.llm import factory as llm_factory

from .voices import (
    ELEVENLABS_DEFAULT_MODEL,
    ELEVENLABS_DEFAULT_VOICE,
    ELEVENLABS_OUTPUT_FORMAT,
    OPENAI_DEFAULT_MODEL,
    OPENAI_DEFAULT_VOICE,
    TTS_FORMAT,
    TTS_SPEED,
)

logger = logging.getLogger(__name__)

ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech"

# A long question plus network round-trip; ElevenLabs streams the whole clip
# before returning, so this is generous on purpose (a timeout here trips the
# fallback provider, which costs the user a slower first question, not silence).
ELEVENLABS_TIMEOUT_SECONDS = 30.0


@runtime_checkable
class TTSProvider(Protocol):
    """Turns text into MP3 bytes. One implementation per vendor."""

    name: str
    default_voice: str

    async def synthesize(self, text: str, voice: str) -> bytes: ...


class OpenAITTSProvider:
    """The incumbent backend (kept as backup, see module docstring)."""

    name = "openai"

    def __init__(self, model: str = OPENAI_DEFAULT_MODEL, voice: Optional[str] = None):
        # TTS is direct-only: OpenRouter does not serve OpenAI TTS (issue #53).
        self.client = llm_factory.openai_client(async_=True, direct=True)
        self.model = model
        self.default_voice = voice or OPENAI_DEFAULT_VOICE

    async def synthesize(self, text: str, voice: str) -> bytes:
        response = await self.client.audio.speech.create(
            model=self.model,
            voice=voice,
            input=text,
            response_format=TTS_FORMAT,
            speed=TTS_SPEED,
        )
        return response.content


class ElevenLabsTTSProvider:
    """Primary backend. Shares `ELEVENLABS_API_KEY` with realtime STT.

    That shared key is why a synthesis failure must not be fatal: the key
    carries one credit budget for both reading questions *and* transcribing
    answers, so exhausting it would otherwise take the whole voice loop down.
    """

    name = "elevenlabs"

    def __init__(
        self,
        model: str = ELEVENLABS_DEFAULT_MODEL,
        voice: Optional[str] = None,
        api_key: Optional[str] = None,
    ):
        self.model = model
        self.default_voice = voice or ELEVENLABS_DEFAULT_VOICE
        self._api_key = api_key

    @property
    def api_key(self) -> Optional[str]:
        # Read late, not at construction: tests and the RC-style env reloads
        # mutate the environment after services are wired up.
        return self._api_key or os.environ.get("ELEVENLABS_API_KEY")

    async def synthesize(self, text: str, voice: str) -> bytes:
        api_key = self.api_key
        if not api_key:
            raise RuntimeError("ELEVENLABS_API_KEY is not set")

        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{ELEVENLABS_TTS_URL}/{voice}",
                params={"output_format": ELEVENLABS_OUTPUT_FORMAT},
                headers={"xi-api-key": api_key, "Content-Type": "application/json"},
                json={"text": text, "model_id": self.model},
                timeout=ELEVENLABS_TIMEOUT_SECONDS,
            )

        if response.status_code != 200:
            # Quota exhaustion arrives as 401 quota_exceeded, not 429 — surface
            # the upstream body so the log says *why* the fallback kicked in.
            raise RuntimeError(
                f"ElevenLabs TTS {response.status_code}: {response.text[:200]}"
            )

        return response.content


_BUILDERS = {
    "elevenlabs": ElevenLabsTTSProvider,
    "openai": OpenAITTSProvider,
}


def build_provider(
    name: str, model: Optional[str] = None, voice: Optional[str] = None
) -> TTSProvider:
    """Instantiate a provider by name (`elevenlabs` / `openai`)."""
    builder = _BUILDERS.get(name.strip().lower())
    if builder is None:
        raise ValueError(
            f"Unknown TTS provider {name!r} (expected one of {sorted(_BUILDERS)})"
        )
    kwargs = {}
    if model:
        kwargs["model"] = model
    if voice:
        kwargs["voice"] = voice
    return builder(**kwargs)
