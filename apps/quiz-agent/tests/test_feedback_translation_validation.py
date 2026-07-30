"""Tests for validated caching in translate_feedback (#133 audit V10).

translate_feedback carries the correct answer the session announces out loud
(flow._translate_correct_answer), and its cache is the durable SQLite store — no TTL,
no invalidation. Storing raw LLM output therefore pinned one bad or empty translation
of the announced answer to that (text, language) key forever; an empty completion was
cached as "" and served as the answer. These tests encode WHY the validation gate
matters: a rejected completion must be retried, must never reach memory or disk, and a
later healthy call must still be able to produce the real translation.
"""

import asyncio
import os
import sqlite3
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Add shared package to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation.translator import TranslationService


@pytest.fixture
def store_url(tmp_path):
    """Per-test on-disk store URL — tests must never touch ./data."""
    return f"sqlite:///{tmp_path}/translations.db"


@pytest.fixture
def service(store_url):
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService(store_url=store_url)


def mock_response(content: str):
    """Build a mock OpenAI chat completion response carrying `content`."""
    mock_message = MagicMock()
    mock_message.content = content
    mock_choice = MagicMock()
    mock_choice.message = mock_message
    response = MagicMock()
    response.choices = [mock_choice]
    return response


def disk_rows(tmp_path):
    """Read the on-disk table via stdlib sqlite3, independent of the store class."""
    with sqlite3.connect(tmp_path / "translations.db") as conn:
        return conn.execute(
            "SELECT kind, source_text, target_language, version, translated_text"
            " FROM translations"
        ).fetchall()


# A correct answer long enough that a 1-word reply fails the ratio guard.
ANSWER = "The Eiffel Tower in Paris, France"
ANSWER_SK = "Eiffelova veža v Paríži vo Francúzsku"


def test_empty_completion_never_cached_and_falls_back(service, tmp_path):
    """The bug in its purest form: an empty completion must not become the permanent
    answer for this text. It is rejected on every attempt, English is served, and
    nothing lands in memory or on disk."""
    service.client.chat.completions.create = AsyncMock(return_value=mock_response(""))

    with patch("app.translation.translator.sentry_sdk"):
        result = asyncio.run(service.translate_feedback(ANSWER, "sk"))

    assert result == ANSWER  # English source, not ""
    assert service._cache == {}
    assert disk_rows(tmp_path) == []


def test_garbage_completion_never_cached_and_falls_back(service, tmp_path):
    """A non-empty but implausible completion (fails the length-ratio guard) is
    treated the same as garbage in translate_question — rejected, not cached."""
    service.client.chat.completions.create = AsyncMock(return_value=mock_response("ok"))

    with patch("app.translation.translator.sentry_sdk"):
        result = asyncio.run(service.translate_feedback(ANSWER, "sk"))

    assert result == ANSWER
    assert service._cache == {}
    assert disk_rows(tmp_path) == []


def test_rejection_spends_full_retry_budget(service):
    """Validation failures retry inside the call (up to TRANSLATION_MAX_ATTEMPTS=3):
    a single stochastic bad completion must not cost the player an English answer."""
    service.client.chat.completions.create = AsyncMock(return_value=mock_response(""))

    with patch("app.translation.translator.sentry_sdk"):
        asyncio.run(service.translate_feedback(ANSWER, "sk"))

    assert service.client.chat.completions.create.call_count == 3


def test_retry_recovers_and_caches_the_valid_translation_once(service, tmp_path):
    """An invalid completion followed by a valid one recovers within the budget; only
    the validated text is cached, and the repeat is a hit (the #69 cost win holds)."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[mock_response(""), mock_response(ANSWER_SK)]
    )

    first = asyncio.run(service.translate_feedback(ANSWER, "sk"))
    second = asyncio.run(service.translate_feedback(ANSWER, "sk"))

    assert first == second == ANSWER_SK
    assert service.client.chat.completions.create.call_count == 2  # no 3rd call
    rows = disk_rows(tmp_path)
    assert len(rows) == 1
    assert rows[0][4] == ANSWER_SK


def test_rejected_fallback_is_retryable_next_call(service):
    """Not caching the fallback is the whole point: the next call must be able to
    produce the real Slovak answer instead of serving English forever."""
    service.client.chat.completions.create = AsyncMock(return_value=mock_response(""))
    with patch("app.translation.translator.sentry_sdk"):
        first = asyncio.run(service.translate_feedback(ANSWER, "sk"))
    assert first == ANSWER

    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(ANSWER_SK)
    )
    second = asyncio.run(service.translate_feedback(ANSWER, "sk"))

    assert second == ANSWER_SK


def test_all_rejected_reports_once_with_validation_kind(service):
    """Fail loud, once: an all-rejected feedback translation is invisible in logs alone,
    and the report doubles as the calibration data for the validation thresholds."""
    service.client.chat.completions.create = AsyncMock(return_value=mock_response(""))

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        asyncio.run(service.translate_feedback(ANSWER, "sk", session_id="sess-1"))

    mock_sentry.capture_message.assert_called_once()
    message = mock_sentry.capture_message.call_args[0][0]
    assert "validation_reject" in message
    assert f"feedback_len={len(ANSWER)}" in message
    assert "translated_len=0" in message
    assert "sess-1" in message
