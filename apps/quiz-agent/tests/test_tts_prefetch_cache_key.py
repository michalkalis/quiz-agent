"""The TTS warm-up must warm the exact cache key /question/audio reads.

Why this matters: /question/audio synthesizes the digit-*normalized* text
(founder bug 2026-07-12 — tts-1 reads embedded digits with English
pronunciation inside Slovak), and the cache key is a hash of that final text.
If the prefetch warms the raw text instead, then for every Slovak/Czech
question containing a number the warm-up writes a key nobody ever reads: the
prefetch is a silent double-spend on OpenAI TTS *and* the driver still pays the
full synthesis latency on the hands-free hot path — the exact cost the prefetch
exists to avoid.
"""

import asyncio

import pytest

from app.quiz.flow import prefetch_question_audio
from app.tts.cache import TTSCache
from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.voices import DEFAULT_VOICE


class _RecordingTTS:
    """Captures the text the prefetch actually sends to synthesis."""

    def __init__(self) -> None:
        self.texts: list[str] = []
        self.called = asyncio.Event()

    async def synthesize_question(self, question_text: str) -> bytes:
        self.texts.append(question_text)
        self.called.set()
        return b"audio"


@pytest.mark.asyncio
async def test_prefetch_warms_the_key_the_route_reads(tmp_path):
    """Slovak question with a year: prefetch key == /question/audio key."""
    question = "V roku 1969 pristáli ľudia na Mesiaci."
    route_text = normalize_numbers_for_tts(question, "sk")

    tts = _RecordingTTS()
    prefetch_question_audio(tts, question, "sk")
    await asyncio.wait_for(tts.called.wait(), timeout=1)

    cache = TTSCache(cache_dir=str(tmp_path / "tts_cache"))
    route_key = cache._hash(route_text, DEFAULT_VOICE)
    raw_key = cache._hash(question, DEFAULT_VOICE)

    # Guard: the fixture must actually be rewritten by normalization, otherwise
    # the assertion below would pass for the wrong reason.
    assert route_key != raw_key

    assert cache._hash(tts.texts[0], DEFAULT_VOICE) == route_key
