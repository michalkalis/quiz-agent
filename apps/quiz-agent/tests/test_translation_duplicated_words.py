"""Glued / duplicated word guard in translations (#171 Track G).

A live Slovak session served "Westminsterského palácapalác": the model glued a
word to a truncated repeat of itself, validation (emptiness + length only) let it
through, and the durable cache — which has no TTL — kept serving it. These tests
encode why the guard exists:

  1. The artifact shapes must be REJECTED, because a rejected translation is
     retried and, failing that, degrades to English — a wrong word never reaches
     the player's ears.
  2. Real reduplication (Baden-Baden, Sing Sing, Wagga Wagga) must PASS, because
     a false positive burns an extra LLM call and then serves English for a
     perfectly good Slovak translation.
  3. The rejection must ride the EXISTING retry loop, not a new fallback path.
"""

import asyncio
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation.duplication import find_duplicated_word
from app.translation.translator import TranslationService


@pytest.fixture
def service(tmp_path):
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService(store_url=f"sqlite:///{tmp_path}/translations.db")


def mock_response(content: str):
    message = MagicMock()
    message.content = content
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]
    return response


# The production defect, verbatim, and the same sentence written correctly.
BAD_SK = "V ktorom meste stojí veža Big Ben, súčasť Westminsterského palácapalác?"
GOOD_SK = "V ktorom meste stojí veža Big Ben, súčasť Westminsterského paláca?"
ORIGINAL = "In which city stands the Big Ben tower, part of the Palace of Westminster?"


class TestDetector:
    """The detector itself — two shapes in, everything else through."""

    def test_glued_repeat_with_truncated_second_copy(self):
        """The shipped defect: "paláca" + "palác". Detecting only the exact X+X
        shape would have missed the very case that caused this issue."""
        assert find_duplicated_word(BAD_SK) == "palácapalác"

    def test_glued_repeat_exact(self):
        assert find_duplicated_word("Stojí pri Westminsterskom palácpalác dnes.") == (
            "palácpalác"
        )

    def test_immediate_word_repetition(self):
        assert find_duplicated_word("Súčasť Westminsterského paláca paláca?") == (
            "paláca paláca"
        )

    def test_repetition_is_caught_across_case_and_punctuation(self):
        """The model stutters mid-sentence with its own capitalisation and commas;
        a case-sensitive check would miss half the real occurrences."""
        assert find_duplicated_word("Bolo to tak, tak jasné.") == "tak tak"
        assert find_duplicated_word("Palác Palác") == "palác palác"

    def test_short_stutter_is_caught(self):
        """ "že že" is a stutter, not a name — no minimum length shields it."""
        assert find_duplicated_word("Je pravda, že že Paríž leží na Seine?") == "že že"

    @pytest.mark.parametrize(
        "text",
        [
            GOOD_SK,
            "Ktoré mesto sa volá Baden-Baden?",  # hyphenated reduplicated name
            "Kde stojí väznica Sing Sing?",
            "Ktorá austrálska obec sa volá Wagga Wagga?",
            "Ktorý ostrov sa volá Bora Bora?",
            "Ako sa volá hlavné mesto Americkej Samoy? Pago Pago.",
            "Ktorá kapela nahrala Rio? Duran Duran.",
            "Z akej suroviny sa robí kuskus? Couscous je z pšenice.",
            "Aké je hlavné mesto Francúzska?",
            "Mama mu to povedala.",  # "mama" is X+X but under the 4-char half
            "b" * 32,  # a run of one letter is not a word glued to its repeat
        ],
    )
    def test_legitimate_text_passes(self, text):
        assert find_duplicated_word(text) is None

    def test_empty_text_is_not_a_duplicate(self):
        assert find_duplicated_word("") is None


class TestValidatorRejects:
    """Both validators must reject, since both write straight into the cache."""

    def test_validate_translation_rejects_glued_repeat(self, service):
        assert service._validate_translation(ORIGINAL, BAD_SK, "sk") is None

    def test_validate_translation_accepts_the_clean_sentence(self, service):
        """Same sentence, one word fixed — the guard must not be rejecting on
        length or on the legitimate "Big Ben" that sits in both strings."""
        assert service._validate_translation(ORIGINAL, GOOD_SK, "sk") == GOOD_SK

    def test_validate_payload_rejects_glued_repeat_in_an_option(self, service):
        """Options skip every length heuristic, so before the guard they had no
        quality gate at all — and the option text is what the player hears."""
        payload = {"question": "Where?", "options": {"a": "Palace", "b": "Tower"}}
        translated = {
            "question": "Kde to je?",
            "options": {"a": "Palácapalác", "b": "Veža"},
        }
        assert service._validate_payload(payload, translated, "sk") is None

    def test_validate_payload_rejects_immediate_repetition_in_the_stem(self, service):
        payload = {"question": ORIGINAL}
        assert (
            service._validate_payload(
                payload,
                {"question": "Súčasť Westminsterského paláca paláca?"},
                "sk",
            )
            is None
        )

    def test_validate_payload_accepts_a_reduplicated_name(self, service):
        """Sing Sing in an option must survive: a false positive here costs an
        extra LLM call and then serves the player English."""
        payload = {"question": "Which prison?", "options": {"a": "Sing Sing"}}
        translated = {"question": "Ktorá väznica?", "options": {"a": "Sing Sing"}}
        assert service._validate_payload(payload, translated, "sk") == translated


class TestRetryThenFallback:
    """The guard reuses the existing retry-then-English path — no new branch."""

    def test_bad_first_attempt_is_retried_and_the_good_one_is_served(self, service):
        service.client.chat.completions.create = AsyncMock(
            side_effect=[mock_response(BAD_SK), mock_response(GOOD_SK)]
        )
        result = asyncio.run(service.translate_question(ORIGINAL, "sk"))
        assert result == GOOD_SK
        assert service.client.chat.completions.create.await_count == 2

    def test_the_retried_good_translation_is_what_gets_cached(self, service):
        """The whole point of the issue: the artifact must not be the thing that
        lands in the durable, TTL-less cache."""
        service.client.chat.completions.create = AsyncMock(
            side_effect=[mock_response(BAD_SK), mock_response(GOOD_SK)]
        )
        asyncio.run(service.translate_question(ORIGINAL, "sk"))
        assert service._cache[("question", ORIGINAL, "sk")] == GOOD_SK

    def test_persistently_duplicated_output_falls_back_to_english_uncached(
        self, service
    ):
        service.client.chat.completions.create = AsyncMock(
            return_value=mock_response(BAD_SK)
        )
        result = asyncio.run(service.translate_question(ORIGINAL, "sk"))
        assert result == ORIGINAL
        assert ("question", ORIGINAL, "sk") not in service._cache
