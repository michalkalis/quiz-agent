"""#200: letters A–D only when the answers are genuinely numbers.

Founder rule (2026-09-24, #185): MCQ options are numbered 1–4, and switch to
letters only when the answers themselves are numbers — otherwise "dva" would
mean both "option 2" and the answer "2 milióny". Until #200 ANY digit flipped
the scheme, so a spacecraft question ("Apollo 11", "Gemini 7") came out lettered
and the driver lost the plain "jedna / dva / tri" he was promised (TF test
2026-10-12). Founder decision 2026-10-12: keep the rule, narrow "a number".

What must hold, in sk / cs / en:
- a name that merely contains a digit is NOT a number → numbers scheme, so
  "dva" selects slot 2;
- years, counts and amounts ARE numbers → letters scheme, so a spoken number
  can only ever name the value, never a slot;
- the label the screen shows, the label the audio reads and the slot the
  matcher resolves come from one decision and can never disagree.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from app.client_capabilities import OPTION_LABELS
from app.evaluation.mcq_matcher import label_scheme, match_option, option_labels
from app.evaluation.numeric_option import is_numeric_option
from app.serializers import _with_option_labels
from app.tts.spoken_text import spoken_question_text

SPACECRAFT = {"a": "Apollo 11", "b": "Apollo 13", "c": "Gemini 7", "d": "Vostok 1"}
AMOUNTS_SK = {
    "a": "Približne 200 tisíc",
    "b": "2 milióny",
    "c": "20 %",
    "d": "5 rokov",
}


@pytest.mark.parametrize(
    "value",
    [
        # years and plain counts
        "1918",
        "2025",
        "V roku 1918",
        # sk amounts
        "Približne 200 tisíc",
        "2 milióny",
        "20 %",
        "5 rokov",
        "Viac ako 100",
        "asi päť",
        "Dvadsaťpäť",
        "štyri",
        # cs amounts
        "Přibližně 200 tisíc",
        "2 miliony",
        "5 let",
        "Více než 100",
        "Pětadvacet",
        "pět set",
        "Čtyři",
        # en amounts
        "About 200,000",
        "2 million",
        "20%",
        "5 years",
        "Twenty-five",
        "Four",
        "1990s",
    ],
)
def test_years_counts_and_amounts_are_numbers(value):
    assert is_numeric_option(value) is True


@pytest.mark.parametrize(
    "value",
    [
        # names that merely contain a number — the #200 report
        "Apollo 11",
        "Gemini 7",
        "Vostok 1",
        "Boeing 747",
        "Formula 1",
        "Catch-22",
        "Ľudovít XIV.",
        # number words that are also everyday words, standing alone
        "Pat",
        "Pet",
        "Set",
        # plain text
        "Paríž",
        "Nikdy",
        "Never",
        "Sestra",
    ],
)
def test_a_name_with_a_number_in_it_is_not_a_number(value):
    assert is_numeric_option(value) is False


def test_spacecraft_options_are_numbered_and_dva_selects_slot_two():
    """The founder's case: nothing here is an amount, so the driver gets the
    1–4 he was promised and "dva" picks the second option."""
    assert label_scheme(SPACECRAFT) == "numbers"
    assert option_labels(SPACECRAFT) == {"a": "1", "b": "2", "c": "3", "d": "4"}
    assert match_option("dva", SPACECRAFT) == "b"
    assert match_option("Gemini 7", SPACECRAFT) == "c"


@pytest.mark.parametrize(
    "options",
    [
        AMOUNTS_SK,
        {"a": "Přibližně 200 tisíc", "b": "2 miliony", "c": "20 %", "d": "5 let"},
        {"a": "About 200,000", "b": "2 million", "c": "20%", "d": "5 years"},
        {"a": "1918", "b": "1945", "c": "1968", "d": "1989"},
    ],
)
def test_genuine_amounts_are_lettered_so_a_spoken_number_never_picks_a_slot(options):
    """With "2 milióny" among the answers, "dva" must not silently grade slot
    2 — in the letters scheme it is unmatched and the driver is asked again."""
    assert label_scheme(options) == "letters"
    assert match_option("dva", options) is None
    assert match_option("béčko", options) == "b"


def test_one_numeric_answer_is_enough_to_letter_the_question():
    """ "jeden" would otherwise mean both slot 1 ("Týždeň") and the answer
    "1 deň" in slot 3 — grading the slot would score a choice never made."""
    options = {"a": "Týždeň", "b": "Mesiac", "c": "1 deň", "d": "Rok"}
    assert label_scheme(options) == "letters"
    assert match_option("jeden", options) is None


@pytest.mark.parametrize(
    "options,first_label,spoken_first",
    [
        (SPACECRAFT, "1", "Jedna: Apollo 11"),
        (AMOUNTS_SK, "A", "A: Približne 200 tisíc"),
    ],
)
def test_screen_audio_and_matcher_share_one_scheme(options, first_label, spoken_first):
    """The label the app draws (serializer), the label the audio reads
    (spoken text) and the slot the matcher resolves must come from one
    decision — a screen saying "1" while the audio says "A" strands the driver."""
    served = _with_option_labels({"possible_answers": dict(options)})
    assert served["option_labels"]["a"] == first_label
    session = SimpleNamespace(language="sk", client_capabilities=[OPTION_LABELS])
    assert spoken_first in spoken_question_text("Otázka?", options, session)
