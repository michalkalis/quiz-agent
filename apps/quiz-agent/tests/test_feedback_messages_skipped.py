"""Tests for the "skipped" correct-answer template in every locale (#133 audit V11).

No locale had a "skipped" key, so get_correct_answer_message() fell through to its
hardcoded English sentence — reachable in a real Slovak session whenever an answer
intent arrives with an empty extracted answer (the evaluator returns "skipped" and the
flow asks for skipped feedback audio). The player then heard the announced correct
answer in English. These tests encode WHY the keys matter: every locale must answer for
every result the evaluator can emit, in that locale, with the answer spoken inside it.
"""

import os
import sys

import pytest

# Add shared package to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation.feedback_messages import (
    CORRECT_ANSWER_TEMPLATES,
    FEEDBACK_MESSAGES,
    get_correct_answer_message,
)

ANSWER = "Paríž"
# The hardcoded fallback in get_correct_answer_message — hearing this in a non-English
# session is the defect.
ENGLISH_FALLBACK = f"The correct answer is {ANSWER}."


@pytest.mark.parametrize("language", sorted(CORRECT_ANSWER_TEMPLATES))
def test_skipped_template_exists_and_speaks_the_answer(language):
    """Every locale must have a "skipped" template that names the correct answer —
    a missing key silently degrades to the English fallback sentence."""
    assert "skipped" in CORRECT_ANSWER_TEMPLATES[language]

    message = get_correct_answer_message("skipped", ANSWER, language)
    assert ANSWER in message
    assert "{answer}" not in message


@pytest.mark.parametrize(
    "language", sorted(lang for lang in CORRECT_ANSWER_TEMPLATES if lang != "en")
)
def test_skipped_message_is_not_english(language):
    """The point of the fix: a non-English session must not hear the English fallback."""
    assert get_correct_answer_message("skipped", ANSWER, language) != ENGLISH_FALLBACK


def test_skipped_message_slovak_is_localized():
    """Slovak is the language the app is actually tested in — assert it explicitly and
    not only via the parametrized sweep."""
    message = get_correct_answer_message("skipped", ANSWER, "sk")
    assert message == "Preskočené. Správna odpoveď je Paríž."
    assert "The correct answer" not in message


@pytest.mark.parametrize("language", sorted(CORRECT_ANSWER_TEMPLATES))
def test_skipped_template_opens_with_the_locale_skip_word(language):
    """The announced version must use the same localized skip wording as the short
    feedback message, so a session never mixes two vocabularies for one event."""
    skip_word = FEEDBACK_MESSAGES[language]["skipped"]
    assert CORRECT_ANSWER_TEMPLATES[language]["skipped"].startswith(skip_word)


def test_every_locale_covers_every_result_key():
    """Locale template sets must stay in lockstep with English: any result key present
    for "en" but missing elsewhere is another silent English leak waiting to happen."""
    expected = set(CORRECT_ANSWER_TEMPLATES["en"])
    for language, templates in CORRECT_ANSWER_TEMPLATES.items():
        assert set(templates) == expected, f"{language} template keys drifted"
