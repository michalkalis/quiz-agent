"""The TTS warm-up must warm the exact cache key /question/audio reads.

Why this matters: the cache key is a hash of the final synthesized string, and
that string is not the raw question. It has the digits spelled out (founder bug
2026-07-12 — tts-1 reads embedded digits with English pronunciation inside
Slovak) and, for multiple choice, the spoken option list appended. If the
warm-up hashes anything else, it writes a key nobody ever reads: a silent
double-spend on TTS *and* the driver still pays the full synthesis latency on
the hands-free hot path — the exact cost the warm-up exists to avoid.

Both tests drive the two REAL call sites (/start warms, /question/audio reads)
and compare the strings they actually synthesized, rather than re-deriving
either one in the test — a test that rebuilt the expected string would agree
with itself while the two sites disagreed in production.
"""

import asyncio

import pytest
from app.tts.cache import TTSCache
from app.tts.voices import DEFAULT_VOICE
from quiz_shared.models.question import Question
from tests.question_audio_harness import (
    RecordingTTS,
    question_audio,
    start_quiz_for,
)

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


def _sk_question(question_text: str, **kwargs) -> Question:
    return Question(
        id="q_sk",
        question=question_text,
        topic="Science",
        category="general",
        difficulty="medium",
        **kwargs,
    )


async def _warmed_and_served(question: Question) -> tuple[str, str]:
    """Return (text the warm-up synthesized, text /question/audio synthesized)."""
    prefetch_tts = RecordingTTS()
    manager, session_id, retriever = await start_quiz_for(
        question, "sk", tts_service=prefetch_tts, audio=True
    )
    await asyncio.wait_for(prefetch_tts.called.wait(), timeout=1)

    served = await question_audio(manager, session_id, retriever, RecordingTTS())
    return prefetch_tts.texts[0], served


async def test_prefetch_warms_the_key_the_route_reads(tmp_path):
    """Slovak question with a year: warm-up key == /question/audio key."""
    question = _sk_question(
        "V roku 1969 pristáli ľudia na Mesiaci. Ktorý rok to bol?",
        correct_answer="1969",
    )

    warmed, served = await _warmed_and_served(question)

    cache = TTSCache(cache_dir=str(tmp_path / "tts_cache"))
    # Guard: the served text must genuinely be rewritten by normalization,
    # otherwise the parity assertion would pass for the wrong reason.
    assert cache._hash(served, DEFAULT_VOICE) != cache._hash(
        question.question, DEFAULT_VOICE
    )

    assert cache._hash(warmed, DEFAULT_VOICE) == cache._hash(served, DEFAULT_VOICE)


async def test_prefetch_warms_the_mcq_key_the_route_reads(tmp_path):
    """MCQ: the warm-up must include the spoken options the route appends.

    Same invariant, second way to break it: the route speaks the option list,
    so a warm-up that hashes only the question text is a key nobody reads.
    """
    question = _sk_question(
        "Približne koľko pozemských dní trvá jeden deň na Venuši?",
        type="text_multichoice",
        possible_answers={"a": "10", "b": "100", "c": "240"},
        correct_answer="c",
    )

    warmed, served = await _warmed_and_served(question)

    # Guard: the served text must genuinely carry the options, otherwise the
    # parity assertion would pass on two identical bare questions.
    assert "Možnosti" in served

    cache = TTSCache(cache_dir=str(tmp_path / "tts_cache"))
    assert cache._hash(warmed, DEFAULT_VOICE) == cache._hash(served, DEFAULT_VOICE)
