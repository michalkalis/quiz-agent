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
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation.translator import TranslationService


@pytest.fixture
def service(tmp_path):
    """Create a TranslationService with a dummy API key, isolated from ./data."""
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService(store_url=f"sqlite:///{tmp_path}/translations.db")


ORIGINAL_QUESTION = (
    "What is the capital city of France and why is it historically significant?"
)
assert len(ORIGINAL_QUESTION) == 74  # the length every ratio below is computed from


class TestValidateTranslation:
    """``_validate_translation`` is the gate between the LLM and the player.

    It has exactly two rejection rules, and each one exists because of a
    different real failure:

    * **Absolute floor** — a sub-15-char translation of a question that is itself
      ≥ 30 chars is garbage ("suchy bodliak"), not a translation. The 30-char
      qualifier was added because the bare floor was discarding legitimate
      compact Slovak translations of short (T/F) prompts and leaking English
      back to the player.
    * **Length ratio** — under 30% of the original means the model truncated or
      answered instead of translating.

    Every expected value below is stated as a literal computed by hand from the
    thresholds, never re-derived from the function under test.
    """

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
        """'suchy bodliak' is 13 chars against a 74-char question — under the
        15-char floor, and the original is well past the 30-char qualifier, so
        the absolute floor is the rule that must reject it."""
        assert len("suchy bodliak") == 13
        result = service._validate_translation(ORIGINAL_QUESTION, "suchy bodliak", "sk")
        assert result is None

    def test_fifteen_chars_clears_the_floor_but_still_fails_the_ratio(self, service):
        """15 chars is exactly ON the floor (``< 15`` — so not rejected by it),
        which makes this the case that proves the ratio rule is a SECOND,
        independent gate: 15/74 = 0.20, under 0.3, so it is still rejected. If
        the ratio check were ever dropped, this is the test that notices."""
        result = service._validate_translation(ORIGINAL_QUESTION, "a" * 15, "sk")
        assert result is None

    def test_compact_translation_of_a_short_question_is_accepted(self, service):
        """The 30-char qualifier on the floor, which is the whole point of it: a
        13-char Slovak rendering of an 11-char T/F prompt is legitimate. The bare
        floor used to reject exactly this and leak English to the player, so this
        must NOT be None."""
        original = "Is it true?"  # 11 chars — under the 30-char qualifier
        translated = "Je to pravda?"  # 13 chars — under the 15-char floor
        result = service._validate_translation(original, translated, "sk")
        assert result == translated  # ratio 13/11 = 1.18, comfortably over 0.3

    def test_short_but_valid_ratio_passes(self, service):
        """Short original, 15-char translation: clears the floor on length and
        the ratio at 15/14 = 1.07."""
        short_original = "What is 2 + 2?"  # 14 chars
        translated = "Koľko je 2 + 2?"  # 15 chars
        result = service._validate_translation(short_original, translated, "sk")
        assert result == translated

    def test_low_ratio_rejected(self, service):
        """A translation long enough to clear the 15-char floor but only 27% of
        the original — the model summarised instead of translating. 25/91 = 0.27,
        under the 0.3 ratio, so it is rejected."""
        long_original = "What is the name of the largest planet in our solar system and how many moons does it have?"
        short_translation = "Aká je najväčšia planéta?"
        assert (len(short_translation), len(long_original)) == (25, 91)
        result = service._validate_translation(long_original, short_translation, "sk")
        assert result is None

    def test_ratio_just_over_the_threshold_is_accepted(self, service):
        """The other side of the same boundary: 32% of the original passes. Pins
        the threshold as 0.3 rather than "generously short is fine" — a drift to
        0.5 would silently start discarding valid terse translations."""
        original = "a" * 100
        translated = "b" * 32  # ratio 0.32
        result = service._validate_translation(original, translated, "sk")
        assert result == translated

    def test_adequate_ratio_passes(self, service):
        """The normal case: 30 chars against 31, ratio 0.97 — both gates clear."""
        original = "What is the capital of Slovakia?"  # 31 chars
        translated = "Aké je hlavné mesto Slovenska?"  # 30 chars
        result = service._validate_translation(original, translated, "sk")
        assert result == translated

    def test_translation_stripped(self, service):
        """Leading/trailing whitespace should be stripped."""
        original = "What is the capital of France?"
        translated = "  Aké je hlavné mesto Francúzska?  "
        result = service._validate_translation(original, translated, "sk")
        assert result == "Aké je hlavné mesto Francúzska?"

    def test_empty_original_is_rejected_not_divided_by_zero(self, service):
        """An empty original would be a division by zero in the ratio rule. The
        guard forces the ratio to 0, so the translation is rejected — the caller
        falls back to the (empty) original rather than the request blowing up
        mid-quiz."""
        result = service._validate_translation("", "some translation text here", "sk")
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
        result = asyncio.run(
            service.translate_question("What is the capital of France?", "sk")
        )
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
        result = asyncio.run(
            service.translate_question("What is the capital of France?", "sk")
        )
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
