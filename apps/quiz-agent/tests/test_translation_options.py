"""Multiple-choice option values must be translated, cheaply, and never fatally.

The corpus is English-only by standing decision, and only the question text was
ever translated. Since the option read-out shipped, a Slovak session does not
just *show* "the Eiffel Tower" under a Slovak question — it SPEAKS it, inside a
Slovak sentence, in a Slovak voice. That is the bug these tests close.

They encode the three constraints that make it safe to translate a value that is
repeated across the whole corpus:

* cost — a bare numeral is language-neutral and must never reach an LLM, and a
  value that IS translated is billed once for the corpus, not once per question
  that offers it (the cache is keyed by the value, not by the question);
* degradation — a failing translation falls back to the English value, because a
  question with an English option is playable and a 500 is not;
* identity — the option KEYS are the answer identifiers the evaluator, the iOS
  matcher and the spoken letter-names all key off, so they are never touched.
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


def test_numeric_options_never_reach_the_llm(service):
    """Bare numerals are the most common option shape and read the same in every
    language — paying for "240" → "240" would be a bill for nothing, on every
    distinct number in the corpus."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("SHOULD NOT BE CALLED")
    )

    translated = asyncio.run(
        service.translate_options({"a": "10", "b": "100", "c": "240"}, "sk")
    )

    assert translated == {"a": "10", "b": "100", "c": "240"}
    assert service.client.chat.completions.create.call_count == 0


def test_mixed_options_bill_only_the_translatable_ones(service):
    """The numeric skip is per value, not per question: one word among numerals
    still gets translated, and the numerals still cost nothing."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("Nikdy")
    )

    translated = asyncio.run(
        service.translate_options({"a": "1969", "b": "Never", "c": "12 %"}, "sk")
    )

    assert translated == {"a": "1969", "b": "Nikdy", "c": "12 %"}
    assert service.client.chat.completions.create.call_count == 1


def test_repeated_value_translated_once_for_the_whole_corpus(service):
    """The cache key is the option VALUE, not the question.

    "Paris" appears in many questions; a per-question key would re-buy the same
    four words for each of them. This is the entire cost argument for
    translating options at all.
    """
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("Paríž")
    )

    first = asyncio.run(service.translate_options({"a": "Paris"}, "sk"))
    # A different question offering the same value, with a different key.
    second = asyncio.run(service.translate_options({"c": "Paris"}, "sk"))

    assert first == {"a": "Paríž"}
    assert second == {"c": "Paríž"}
    assert service.client.chat.completions.create.call_count == 1


def test_option_kind_does_not_collide_with_question_text(service):
    """Same text, different prompt: an option must not serve a question's cached
    translation (or the reverse) — the `kind` discriminator keeps them apart."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("Je ľad studený?")
    )

    asyncio.run(service.translate_question("Is ice cold?", "sk"))
    asyncio.run(service.translate_options({"a": "Is ice cold?"}, "sk"))

    assert service.client.chat.completions.create.call_count == 2


def test_failed_option_falls_back_to_english_and_stays_playable(service):
    """A translation failure must cost the driver an English word, not the question.

    The value comes back untranslated (and uncached, so the next question can
    still succeed) and the map keeps every key — the caller has no failure mode
    to handle, which is what keeps /start and /question/audio alive.
    """
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("rate limit"), mock_response("Londýn")]
    )

    translated = asyncio.run(
        service.translate_options({"a": "Paris", "b": "London"}, "sk")
    )

    assert translated == {"a": "Paris", "b": "Londýn"}

    retry = asyncio.run(service.translate_options({"a": "Paris"}, "sk"))
    assert retry == {"a": "Paris"}  # fallback was not cached; it recomputed
    assert service.client.chat.completions.create.call_count == 3


def test_chatty_completion_is_rejected(service):
    """The realistic failure for a two-word phrase is a model that explains
    itself. Speaking "The Slovak translation of 'Paris' is 'Paríž'" as an option
    is worse than speaking the English word, so it degrades instead."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(
            "The Slovak translation of the option 'Paris' would be 'Paríž'."
        )
    )

    assert asyncio.run(service.translate_options({"a": "Paris"}, "sk")) == {
        "a": "Paris"
    }


def test_option_keys_are_never_translated(service):
    """Keys are answer identifiers, not prose: the evaluator matches on them, the
    iOS matcher resolves to them, and the read-out speaks them as letter-names.
    Translating one would silently unmap a driver's answer."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("Pravda")
    )

    translated = asyncio.run(service.translate_options({"a": "True"}, "sk"))

    assert list(translated) == ["a"]
    assert translated["a"] == "Pravda"


def test_english_session_short_circuits(service):
    """An English session has nothing to translate and must not touch the LLM."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("SHOULD NOT BE CALLED")
    )

    assert asyncio.run(service.translate_options({"a": "Paris"}, "en")) == {
        "a": "Paris"
    }
    assert service.client.chat.completions.create.call_count == 0
    assert service._cache == {}
