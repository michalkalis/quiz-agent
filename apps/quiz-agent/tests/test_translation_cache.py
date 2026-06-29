"""Tests for the process-lifetime translation cache (#69).

A fresh gpt-4o-mini call per question/feedback made SK sessions ~3.5× the cost of EN
(#49). TranslationService is a process-wide singleton, so caching validated translations
for the process lifetime removes almost all of the repeat cost. These tests encode WHY the
cache matters: a repeat is one LLM call (cost), the cache lives on the singleton (persistence),
the `kind` discriminator stops cross-method collisions, fallbacks/short-circuits are never
cached (correctness), and memory stays bounded at the cap (safety).
"""

import asyncio
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Add shared package to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation import translator as translator_module
from app.translation.translator import TranslationService


@pytest.fixture
def service():
    """Create a TranslationService with a dummy API key."""
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService()


def mock_response(content: str):
    """Build a mock OpenAI chat completion response carrying `content`."""
    mock_message = MagicMock()
    mock_message.content = content
    mock_choice = MagicMock()
    mock_choice.message = mock_message
    mock_response = MagicMock()
    mock_response.choices = [mock_choice]
    return mock_response


# A question + its valid Slovak translation that passes _validate_translation
# (>= 15 chars, length ratio >= 0.3).
QUESTION = "What is the capital city of France?"
QUESTION_SK = "Aké je hlavné mesto Francúzska dnes?"


def test_repeat_question_one_llm_call(service):
    """Repeat = one LLM call, and it persists on the singleton (no new instance built).

    The second identical call must be a cache hit — that is the entire cost win.
    """
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))
    second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert service.client.chat.completions.create.call_count == 1
    assert first == second == QUESTION_SK


def test_repeat_feedback_one_llm_call(service):
    """Repeat feedback = one LLM call on the same singleton instance."""
    feedback = "Correct! Well done."
    feedback_sk = "Správne! Výborne."
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(feedback_sk)
    )

    first = asyncio.run(service.translate_feedback(feedback, "sk"))
    second = asyncio.run(service.translate_feedback(feedback, "sk"))

    assert service.client.chat.completions.create.call_count == 1
    assert first == second == feedback_sk


def test_both_methods_cached_kind_isolates(service):
    """Same text through both methods stays independent — `kind` prevents collision.

    The two methods use different prompts, so identical text must NOT share a cache entry.
    """
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    # Same text T to both methods → two independent misses (kind discriminator).
    asyncio.run(service.translate_question(QUESTION, "sk"))
    asyncio.run(service.translate_feedback(QUESTION, "sk"))
    assert service.client.chat.completions.create.call_count == 2

    # Repeating both → both now hits, no further LLM calls.
    asyncio.run(service.translate_question(QUESTION, "sk"))
    asyncio.run(service.translate_feedback(QUESTION, "sk"))
    assert service.client.chat.completions.create.call_count == 2


def test_error_then_success_recomputes(service):
    """A transient error fallback must NOT poison the cache — a later success still calls."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("rate limit"), mock_response(QUESTION_SK)]
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))
    second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert first == QUESTION  # error fell back to original (not cached)
    assert second == QUESTION_SK  # later success recomputed
    assert service.client.chat.completions.create.call_count == 2


def test_validation_fail_then_success_recomputes(service):
    """A validation-rejected fallback must NOT be cached — a later success still calls."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[mock_response("suchy bodliak"), mock_response(QUESTION_SK)]
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))
    second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert first == QUESTION  # garbage rejected → original (not cached)
    assert second == QUESTION_SK
    assert service.client.chat.completions.create.call_count == 2


def test_feedback_error_then_success_recomputes(service):
    """translate_feedback's only non-success path (except → original) is likewise never cached."""
    feedback = "Correct! Well done."
    feedback_sk = "Správne! Výborne."
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("boom"), mock_response(feedback_sk)]
    )

    first = asyncio.run(service.translate_feedback(feedback, "sk"))
    second = asyncio.run(service.translate_feedback(feedback, "sk"))

    assert first == feedback  # error fell back to original (not cached)
    assert second == feedback_sk
    assert service.client.chat.completions.create.call_count == 2


def test_noop_shortcircuit_untouched(service):
    """No-op passthroughs (source==target / target=='en') never hit the LLM or the cache."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    q = asyncio.run(service.translate_question(QUESTION, "en", "en"))
    f = asyncio.run(service.translate_feedback("Correct!", "en"))

    assert q == QUESTION
    assert f == "Correct!"
    assert service.client.chat.completions.create.call_count == 0
    assert service._cache == {}


def test_cache_bounded_at_cap(service, monkeypatch):
    """Memory is bounded: once the cap is reached, new keys stop being inserted.

    Patch the module-global cap to a small N AFTER the service is built (proving the guard
    reads it at call-time), then translate more than N distinct texts with valid responses.
    The guard must stop storing at the cap while still translating every miss.
    """
    N = 3
    monkeypatch.setattr(translator_module, "CACHE_MAX_ENTRIES", N)

    # A translation long enough that every distinct original validates (ratio >= 0.3).
    valid_sk = "Toto je platný preložený text otázky pre účely tohto testu."
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(valid_sk)
    )

    distinct = N + 2
    for i in range(distinct):
        asyncio.run(
            service.translate_question(f"What is interesting fact number {i}?", "sk")
        )

    # Every miss was translated (guard limits storage, not translation)...
    assert service.client.chat.completions.create.call_count == distinct
    # ...but the cache is capped at N.
    assert len(service._cache) == N
