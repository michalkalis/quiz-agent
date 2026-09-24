"""#185 G: one server-side matcher for every way a driver names an MCQ option.

Founder car test 2026-09-23: the spoken answer "C" was not understood. The #184
batch voice path uploads audio, so the iOS ``MCQTranscriptMatcher`` never ran,
and the server compared the transcript to the option texts verbatim. Founder
decision 2026-09-24: options are labelled 1–4 (letters A–D only when the options
are themselves numbers), and the number, the letter, the ordinal and the option
text are all accepted, in sk / cs / en, declined or colloquial.

Two failure directions matter and both are pinned here:
- a MISS re-asks the player (annoying) — the vocabulary table below;
- a FALSE MATCH grades an option the player did not choose (wrong score) — the
  guard table: ambiguity, negation, names containing an ordinal, labels a
  question does not have. Those must come back ``None`` (unmatched → re-ask).
"""

from __future__ import annotations

import pytest

from app.evaluation.mcq_matcher import (
    label_keyterms,
    label_scheme,
    match_option,
    option_labels,
)

CITIES = {"a": "Paríž", "b": "Londýn", "c": "Berlín", "d": "Madrid"}
YEARS = {"a": "1969", "b": "1970", "c": "1971", "d": "1972"}
COUNTS = {"a": "4", "b": "2", "c": "3", "d": "1"}  # numeric AND shuffled


class TestLabelScheme:
    def test_text_options_are_numbered(self):
        assert label_scheme(CITIES) == "numbers"
        assert option_labels(CITIES) == {"a": "1", "b": "2", "c": "3", "d": "4"}

    @pytest.mark.parametrize(
        "options",
        [YEARS, COUNTS, {"a": "Four", "b": "Five"}, {"a": "3 minutes", "b": "Never"}],
    )
    def test_numeric_options_switch_to_letters(self, options):
        """Otherwise "tri" would mean both "option 3" and the answer "3"."""
        assert label_scheme(options) == "letters"
        assert option_labels(options)["a"] == "A"

    def test_labels_follow_display_order_not_dict_order(self):
        """iOS and question TTS both sort options by key; position N is the N-th
        key in that order, whatever order the dict arrived in."""
        assert option_labels({"c": "Berlín", "a": "Paríž", "b": "Londýn"}) == {
            "a": "1",
            "b": "2",
            "c": "3",
        }

    def test_keyterms_are_the_words_for_the_labels(self):
        assert label_keyterms(option_labels(CITIES), "sk") == [
            "jedna",
            "dva",
            "tri",
            "štyri",
        ]
        assert label_keyterms(option_labels(YEARS), "cs")[2] == "céčko"
        # English letters are never keyterms: a bare "C" is invented from noise.
        assert label_keyterms(option_labels(YEARS), "en") == []


# Every form the founder named (and its declension / colloquial neighbours),
# for the text-option question — numbers scheme.
SPOKEN_THIRD = [
    # letters, as said and as Scribe writes them
    "C", "c", "cé", "Cé.", "céčko", "Céčko prosím", "je to céčko", "option C",
    "the answer is C", "I'd say C", "it's c", "it could be C", "see",
    # numbers — sk / cs / en, digits, colloquial nouns and their cases
    "3", "tri", "tři", "three", "number three", "číslo tri", "trojka",
    "trojku", "trojkou",
    # ordinals, declined
    "tretia", "tretiu", "tretej", "tá tretia možnosť", "třetí", "třetího",
    "third", "the third one", "3rd",
]  # fmt: skip


@pytest.mark.parametrize("spoken", SPOKEN_THIRD)
def test_every_spoken_form_of_option_three_resolves(spoken):
    assert match_option(spoken, CITIES) == "c"


@pytest.mark.parametrize(
    "spoken,key",
    [
        ("dvojka", "b"), ("druhou", "b"), ("the second one", "b"), ("béčko", "b"),
        ("bé", "b"), ("B", "b"), ("dva", "b"), ("druhá", "b"),
        ("čtyřka", "d"), ("štvrtá", "d"), ("čtvrtý", "d"), ("posledná", "d"),
        ("last", "d"), ("jednička", "a"), ("prvá", "a"), ("první", "a"), ("áčko", "a"),
        ("a je to béčko", "b"),  # sk "a" = "and" once a real label is said
    ],
)  # fmt: skip
def test_other_positions_and_forms(spoken, key):
    assert match_option(spoken, CITIES) == key


@pytest.mark.parametrize(
    "spoken,key",
    [
        ("Paríž", "a"),
        ("PARIZ", "a"),  # case and diacritics are irrelevant
        ("je to Londýn", "b"),
        ("Londýne", "b"),  # declension
        ("Parížom", "a"),
        ("Madrit", "d"),  # recogniser near-miss
    ],
)
def test_the_option_text_itself_resolves(spoken, key):
    assert match_option(spoken, CITIES) == key


class TestNumericOptions:
    """Letters scheme: a spoken number names the VALUE, never a slot."""

    def test_number_word_matches_the_numeric_value(self):
        assert match_option("tri", COUNTS) == "c"  # the option "3", not slot 3
        assert match_option("štyri", COUNTS) == "a"  # "4" sits in slot 1
        assert match_option("trojka", COUNTS) == "c"

    def test_letters_and_ordinals_still_address_slots(self):
        assert match_option("B", COUNTS) == "b"
        assert match_option("céčko", COUNTS) == "c"
        assert match_option("tretia", YEARS) == "c"

    def test_a_number_that_is_no_option_is_unmatched_not_a_slot(self):
        assert match_option("tri", YEARS) is None
        assert match_option("1970", YEARS) == "b"


@pytest.mark.parametrize(
    "spoken,options",
    [
        ("xyz", CITIES),
        ("hm", CITIES),
        ("", CITIES),
        ("b alebo c", CITIES),  # two labels: no single choice
        ("nie druhá ale tretia", CITIES),
        ("nie Paríž", CITIES),  # negation must never grade the option it negates
        ("not B", CITIES),
        ("Paríž alebo Londýn", CITIES),
        ("tretia", {"a": "Áno", "b": "Nie"}),  # a label this question lacks
        ("E", CITIES),
        ("it could be B or C", CITIES),
    ],
)
def test_guards_resolve_to_unmatched(spoken, options):
    """A false match scores an option the player did not pick; unmatched only
    asks again. Every ambiguous or negated utterance must be unmatched."""
    assert match_option(spoken, options) is None


def test_an_ordinal_inside_a_name_is_not_a_slot():
    """ "Karol Štvrtý" (Charles IV) names a person; reading "štvrtý" as "the
    fourth option" would grade a slot the player never chose."""
    kings = {"a": "Karol Veľký", "b": "Ľudovít XIV.", "c": "Rudolf II.", "d": "Otto I."}
    assert match_option("Karol Štvrtý", kings) is None
    assert match_option("Karola Veľkého", kings) == "a"  # declined multi-word text


def test_negation_word_inside_an_option_is_not_a_negation():
    assert match_option("Nie", {"a": "Áno", "b": "Nie"}) == "b"


def test_no_options_never_match():
    assert match_option("C", None) is None
    assert match_option("C", {}) is None
