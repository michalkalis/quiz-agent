"""#231 — a Ukrainian player's spoken answer finds the option they named.

Why these matter: an answer the matcher cannot place is asked again, so a label
the audio says but the matcher does not know loops the player forever ("Це" for
option C). Numeric options must get letter labels in Ukrainian too, or "два"
could mean option 2 or the value 2. And a lenient match that misses the
Ukrainian apostrophe or a vowel slip sends an obviously right answer to the
paid judge, or marks it wrong.
"""

from __future__ import annotations

import pytest
from app.evaluation.mcq_matcher import (
    label_keyterms,
    label_scheme,
    match_option,
    option_labels,
    spoken_label,
)
from app.evaluation.numeric_option import is_numeric_option
from app.evaluation.phonetic_match import phonetic_matches
from app.evaluation.voice_match import fold, sounds_like

YEARS = {"a": "1969", "b": "1970", "c": "1971", "d": "1972"}
CITIES = {"a": "Париж", "b": "Київ", "c": "Берлін", "d": "Мадрид"}

# ── Letter labels: what the screen shows, the audio says, the matcher hears ──


def test_uk_audio_names_the_latin_letters_the_screen_shows():
    """The screen shows A–D; the audio must name those letters, not А Б В Г."""
    assert [spoken_label(x, "uk") for x in "ABCD"] == ["А", "Бе", "Це", "Де"]


def test_other_languages_still_read_the_letters_as_letters():
    assert [spoken_label(x, "sk") for x in "ABCD"] == ["A", "B", "C", "D"]
    assert spoken_label("C", "en") == "C"


@pytest.mark.parametrize(
    ("said", "key"),
    [
        # Ukrainian names of the Latin letters, as the audio says them.
        ("а", "a"),
        ("бе", "b"),
        ("це", "c"),
        ("Це.", "c"),
        ("де", "d"),
        # English names, which many players use for Latin letters.
        ("ей", "a"),
        ("бі", "b"),
        ("сі", "c"),
        ("ді", "d"),
        # Cyrillic order (В and Г are the third and fourth letters).
        ("ве", "c"),
        ("ге", "d"),
    ],
)
def test_every_spoken_name_of_a_letter_picks_its_option(said, key):
    assert match_option(said, YEARS) == key


def test_tse_is_a_letter_only_as_the_whole_answer():
    """«це» is also "this is": «це Київ» must match by content, and a lone
    «це» in a numbered question names no label, so it is asked again."""
    assert match_option("це Київ", CITIES) == "b"
    assert match_option("це", CITIES) is None
    assert match_option("це 1971", YEARS) == "c"


@pytest.mark.parametrize("label", ["A", "B", "C", "D"])
def test_spoken_letter_label_round_trips_to_its_option(label):
    """What the question audio says for a label must select that option."""
    labels = option_labels(YEARS)
    key = next(k for k, v in labels.items() if v == label)
    assert match_option(spoken_label(label, "uk"), YEARS) == key


@pytest.mark.parametrize("label", ["1", "2", "3", "4"])
def test_spoken_number_label_round_trips_to_its_option(label):
    labels = option_labels(CITIES)
    key = next(k for k, v in labels.items() if v == label)
    assert match_option(spoken_label(label, "uk"), CITIES) == key


def test_recogniser_hints_follow_the_spoken_letters_without_a_lone_vowel():
    """A bare "а" hint makes the recogniser hear a letter in road noise."""
    assert label_keyterms(option_labels(YEARS), "uk") == ["бе", "це", "де"]


def test_number_noun_in_the_nominative_picks_its_option():
    assert match_option("одиниця", CITIES) == "a"
    assert match_option("одиницю", CITIES) == "a"


# ── Numeric options get letters ──────────────────────────────────────────────


@pytest.mark.parametrize(
    "value",
    [
        "2 мільйони",
        "1969 рік",
        "100 км",
        "50 відсотків",
        "близько 300",
        "п'ять тисяч",
        "понад 2 млн",
        "пів мільйона",
        "1,5 тис. гривень",
    ],
)
def test_ukrainian_amounts_are_numbers(value):
    assert is_numeric_option(value)


@pytest.mark.parametrize("value", ["Аполлон 11", "Київ", "пів"])
def test_ukrainian_names_are_not_numbers(value):
    assert not is_numeric_option(value)


def test_a_question_with_ukrainian_amounts_is_lettered():
    """Numbered labels would let "два" mean option 2 while the answer "2
    мільйони" sits in another slot; with letters, "два" never names a slot."""
    options = {
        "a": "2 мільйони",
        "b": "1 мільйон",
        "c": "5 мільйонів",
        "d": "10 мільйонів",
    }
    assert label_scheme(options) == "letters"
    assert match_option("два", options) != "b"
    assert match_option("бе", options) == "b"


# ── Lenient open answers in Cyrillic ─────────────────────────────────────────


@pytest.mark.parametrize("apostrophe", ["'", "’", "ʼ"])
def test_every_ukrainian_apostrophe_folds_to_one_word(apostrophe):
    assert fold(f"Дев{apostrophe}ятий вал") == "девятий вал"


def test_latin_apostrophes_fold_as_before():
    assert fold("O'Brien") == "o brien"


@pytest.mark.parametrize(
    ("heard", "expected"),
    [
        ("Девʼятий вал", "Дев'ятий вал"),
        ("Дев’ятий вал", "Дев'ятий вал"),
        ("Шевчинко", "Шевченко"),  # one unstressed vowel misheard
        ("Гете", "Ґете"),  # both are correct spellings
        ("Ганна", "Гана"),  # doubled letter
    ],
)
def test_ukrainian_sound_alikes_are_accepted(heard, expected):
    assert sounds_like(heard, expected)


@pytest.mark.parametrize(
    ("heard", "expected"),
    [
        ("бий", "бій"),  # й is a consonant: a different word
        ("Баикал", "Байкал"),
        ("Шевчинка", "Шевченко"),  # two slips, one at the end
        ("Харків", "Херсон"),
    ],
)
def test_different_ukrainian_words_still_go_to_the_judge(heard, expected):
    assert not sounds_like(heard, expected)


def test_phonetic_tier_treats_the_apostrophes_alike():
    assert phonetic_matches("Девʼятий вал", ["Дев'ятий вал"])
    assert not phonetic_matches("бий", ["бій"])
