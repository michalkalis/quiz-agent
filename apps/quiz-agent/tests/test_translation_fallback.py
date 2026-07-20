"""Tests for fail-loud Sentry reporting on translation fallback (#107).

Before this, an exhausted-retries or all-validation-rejected translation fell back to
the original English question with only a `logger.warning` — invisible in Sentry, so a
Slovak session could silently serve an untranslated question with nobody alerted. These
tests encode WHY the reporting matters: exactly one `capture_message` per exhausted
fallback (not per attempt), the message carries enough detail (language, failure kind,
lengths/ratio, session_id) to debug and to calibrate the validation thresholds against,
retries that recover within budget must NOT report, and the fallback-is-never-cached
invariant (#69) must survive the retry-budget bump untouched.
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

from app.translation.translator import TranslationService


def make_service(store_url: str) -> TranslationService:
    """Create a TranslationService with a dummy API key and an explicit store URL."""
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService(store_url=store_url)


@pytest.fixture
def store_url(tmp_path):
    """Per-test on-disk store URL — tests must never touch ./data."""
    return f"sqlite:///{tmp_path}/translations.db"


@pytest.fixture
def service(store_url):
    """Create a TranslationService isolated on a tmp_path store."""
    return make_service(store_url)


def mock_response(content: str):
    """Build a mock OpenAI chat completion response carrying `content`."""
    mock_message = MagicMock()
    mock_message.content = content
    mock_choice = MagicMock()
    mock_choice.message = mock_message
    mock_response = MagicMock()
    mock_response.choices = [mock_choice]
    return mock_response


def disk_rows(tmp_path):
    """Read the on-disk table via stdlib sqlite3, independent of the store class."""
    import sqlite3

    with sqlite3.connect(tmp_path / "translations.db") as conn:
        return conn.execute(
            "SELECT kind, source_text, target_language, version, translated_text"
            " FROM translations"
        ).fetchall()


QUESTION = "What is the capital city of France?"
QUESTION_SK = "Aké je hlavné mesto Francúzska dnes?"


def test_always_raising_reports_once_and_falls_back(service):
    """Every attempt raising an API exception: fall back to English, report exactly
    once (not once per attempt), and the message names the language, the api_error
    kind, and the session_id when one was passed."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=Exception("rate limit")
    )

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        result = asyncio.run(
            service.translate_question(QUESTION, "sk", session_id="sess-abc")
        )

    assert result == QUESTION  # fell back to original, not left hanging
    assert service.client.chat.completions.create.call_count == 3  # full budget spent
    mock_sentry.capture_message.assert_called_once()
    message = mock_sentry.capture_message.call_args[0][0]
    assert "Slovak" in message or "sk" in message
    assert "api_error" in message
    assert "sess-abc" in message


def test_always_invalid_reports_validation_kind_with_lengths(service):
    """Every attempt validation-rejected (too short / bad ratio): report fires with
    the validation kind plus the lengths/ratio that a future EN→SK calibration
    dataset needs — there is no local corpus to tune the 0.3 ratio guard against."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("suchy bodliak")  # 13 chars, fails ratio + floor
    )

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        result = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert result == QUESTION
    mock_sentry.capture_message.assert_called_once()
    message = mock_sentry.capture_message.call_args[0][0]
    assert "validation_reject" in message
    assert f"original_len={len(QUESTION)}" in message
    assert "translated_len=13" in message
    assert "ratio=" in message


def test_third_attempt_recovers_no_report_and_caches(service, tmp_path):
    """Two failures then a valid completion on the 3rd attempt: succeeds within the
    retry budget, must NOT report to Sentry, and — being a validated success — is
    cached (the retryable invariant, #69)."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("boom"), Exception("boom"), mock_response(QUESTION_SK)]
    )

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        result = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert result == QUESTION_SK
    assert service.client.chat.completions.create.call_count == 3
    mock_sentry.capture_message.assert_not_called()

    rows = disk_rows(tmp_path)
    assert len(rows) == 1
    assert rows[0][4] == QUESTION_SK


def test_feedback_raising_reports_once(service):
    """translate_feedback keeps its single-attempt fallback but must now report
    exactly once, with the exception class and session_id when passed."""
    service.client.chat.completions.create = AsyncMock(side_effect=Exception("boom"))

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        result = asyncio.run(
            service.translate_feedback("Correct!", "sk", session_id="sess-xyz")
        )

    assert result == "Correct!"
    assert service.client.chat.completions.create.call_count == 1  # no retry loop
    mock_sentry.capture_message.assert_called_once()
    message = mock_sentry.capture_message.call_args[0][0]
    assert "Exception" in message
    assert "sess-xyz" in message


def test_fallback_still_not_cached_retryable(service):
    """The retryable invariant (#69) must survive the retry-budget bump: an exhausted
    fallback is never cached, so a later call with a now-working client still succeeds."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=Exception("rate limit")
    )
    with patch("app.translation.translator.sentry_sdk"):
        first = asyncio.run(service.translate_question(QUESTION, "sk"))
    assert first == QUESTION

    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )
    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert second == QUESTION_SK
    mock_sentry.capture_message.assert_not_called()
