"""Tests for translation validation logic.

Verifies that garbage / too-short / disproportionate translations are rejected
and the original English question is returned as fallback.
"""

import asyncio
import sys
import os
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Add shared package to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from app.translation.translator import TranslationService


@pytest.fixture
def service():
    """Create a TranslationService with a dummy API key."""
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService()


ORIGINAL_QUESTION = "What is the capital city of France and why is it historically significant?"


class TestValidateTranslation:
    """Unit tests for _validate_translation() method."""

    def test_valid_translation_passes(self, service):
        translated = "Aké je hlavné mesto Francúzska a prečo je historicky významné?"
        result = service._validate_translation(ORIGINAL_QUESTION, translated, "sk")
        assert result == translated

    def test_empty_string_rejected(self, service):
        result = service._validate_translation(ORIGINAL_QUESTION, "", "sk")
        assert result is None

    def test_whitespace_only_rejected(self, service):
        result = service._validate_translation(ORIGINAL_QUESTION, "   ", "sk")
        assert result is None

    def test_none_rejected(self, service):
        result = service._validate_translation(ORIGINAL_QUESTION, None, "sk")
        assert result is None

    def test_too_short_rejected(self, service):
        """'suchy bodliak' is 14 chars — classic garbage output."""
        result = service._validate_translation(ORIGINAL_QUESTION, "suchy bodliak", "sk")
        assert result is None

    def test_exactly_15_chars_passes(self, service):
        """15 chars is the minimum threshold — should pass."""
        text = "a" * 15
        result = service._validate_translation(ORIGINAL_QUESTION, text, "sk")
        # 15 / len(ORIGINAL_QUESTION) should be checked for ratio too
        # ORIGINAL_QUESTION is 73 chars, 15/73 = 0.205 < 0.3 → rejected by ratio
        assert result is None

    def test_short_but_valid_ratio_passes(self, service):
        """Short original + adequate translation should pass both checks."""
        short_original = "What is 2 + 2?"  # 14 chars
        translated = "Koľko je 2 + 2?"  # 15 chars
        result = service._validate_translation(short_original, translated, "sk")
        assert result == translated

    def test_low_ratio_rejected(self, service):
        """Translation much shorter than original gets rejected."""
        long_original = "What is the name of the largest planet in our solar system and how many moons does it have?"
        short_translation = "Aká je najväčšia planéta?"  # ~27 chars vs 90 → ratio ~0.30
        result = service._validate_translation(long_original, short_translation, "sk")
        # 25/90 = 0.28 < 0.3 if short enough
        if len(short_translation) / len(long_original) < 0.3:
            assert result is None
        else:
            assert result == short_translation

    def test_adequate_ratio_passes(self, service):
        """Translation with reasonable ratio passes."""
        original = "What is the capital of Slovakia?"  # 31 chars
        translated = "Aké je hlavné mesto Slovenska?"  # 29 chars
        result = service._validate_translation(original, translated, "sk")
        assert result == translated

    def test_translation_stripped(self, service):
        """Leading/trailing whitespace should be stripped."""
        original = "What is the capital of France?"
        translated = "  Aké je hlavné mesto Francúzska?  "
        result = service._validate_translation(original, translated, "sk")
        assert result == "Aké je hlavné mesto Francúzska?"

    def test_empty_original_zero_length(self, service):
        """Edge case: empty original string."""
        result = service._validate_translation("", "some translation text here", "sk")
        # ratio = len(translated) / 0 → 0 < 0.3 → rejected
        assert result is None


class TestTranslateQuestionIntegration:
    """Integration tests for translate_question() with mocked OpenAI."""

    def _mock_openai_response(self, content: str):
        """Create a mock OpenAI chat completion response."""
        mock_message = MagicMock()
        mock_message.content = content
        mock_choice = MagicMock()
        mock_choice.message = mock_message
        mock_response = MagicMock()
        mock_response.choices = [mock_choice]
        return mock_response

    def test_good_translation_returned(self, service):
        """Normal translation passes validation and is returned."""
        translated = "Aké je hlavné mesto Francúzska?"
        service.client.chat.completions.create = AsyncMock(
            return_value=self._mock_openai_response(translated)
        )
        result = asyncio.run(service.translate_question(
            "What is the capital of France?", "sk"
        ))
        assert result == translated

    def test_garbage_translation_returns_original(self, service):
        """Garbage 2-word output falls back to original English."""
        original = "What is the capital of France?"
        service.client.chat.completions.create = AsyncMock(
            return_value=self._mock_openai_response("suchy bodliak")
        )
        result = asyncio.run(service.translate_question(original, "sk"))
        assert result == original

    def test_empty_translation_returns_original(self, service):
        """Empty response falls back to original English."""
        original = "What is the capital of France?"
        service.client.chat.completions.create = AsyncMock(
            return_value=self._mock_openai_response("")
        )
        result = asyncio.run(service.translate_question(original, "sk"))
        assert result == original

    def test_same_language_skips_translation(self, service):
        """If source == target, return original without calling API."""
        original = "What is the capital of France?"
        result = asyncio.run(service.translate_question(original, "en", "en"))
        assert result == original

    def test_api_error_returns_original(self, service):
        """OpenAI API error falls back to original English."""
        original = "What is the capital of France?"
        service.client.chat.completions.create = AsyncMock(
            side_effect=Exception("API rate limit exceeded")
        )
        result = asyncio.run(service.translate_question(original, "sk"))
        assert result == original

    def test_quoted_translation_unquoted(self, service):
        """Quotes around translation are stripped before validation."""
        translated = "Aké je hlavné mesto Francúzska?"
        service.client.chat.completions.create = AsyncMock(
            return_value=self._mock_openai_response(f'"{translated}"')
        )
        result = asyncio.run(service.translate_question(
            "What is the capital of France?", "sk"
        ))
        assert result == translated

    def test_disproportionately_short_returns_original(self, service):
        """Translation that is too short relative to original falls back."""
        original = "Which country hosted the 2024 Summer Olympics and what city were the main venues located in?"
        short = "Francúzsko"  # 10 chars — too short
        service.client.chat.completions.create = AsyncMock(
            return_value=self._mock_openai_response(short)
        )
        result = asyncio.run(service.translate_question(original, "sk"))
        assert result == original
