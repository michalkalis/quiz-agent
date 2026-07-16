"""Unit tests for the deterministic craft guards (#72 reviewer upgrade).

Why these scenarios: the guards encode the founder's calibration ground truth
(2026-07-09/10). Every positive case is a question class the founder penalised
live; every negative case is a question the founder rated 4-5/5 — a guard that
flags those would silently delete exactly the questions we want, so the
false-positive cases are the load-bearing half of this file.
"""

from __future__ import annotations

from app.scoring.craft_guards import (
    long_answer_reason,
    stem_leak_reason,
    tf_imbalance_excess,
    true_false_key,
    undated_record_reason,
    units_reason,
)

# --- stem_leak_reason ---------------------------------------------------------


def test_flags_exact_answer_word_in_stem() -> None:
    """The archetypal leak: the stem names the answer outright."""
    assert stem_leak_reason(
        "What razor-sharp item can human stomach acid dissolve? ", "Razor blade"
    ) is not None


def test_flags_derivative_leak_napoleon_class() -> None:
    """Founder Q29 (4/5, docked for the leak): stem says 'British wartime
    propaganda', answer is 'Britain' — a derivative giveaway the founder
    called out verbatim ('the question seems to reveal the answer')."""
    assert stem_leak_reason(
        "The myth that Napoleon was unusually short came from British wartime "
        "propaganda cartoons of which country?",
        "Britain",
    ) is not None


def test_does_not_flag_founder_five_of_five_numeric() -> None:
    """Founder D4 (5/5): 'How many times does the human heart beat in a day?'
    → '100,000 times'. 'times' appears in both but is generic quiz prose, not
    a leak — flagging this would delete a founder-top-rated question."""
    assert stem_leak_reason(
        "How many times does the human heart beat in a day on average?",
        "100,000 times",
    ) is None


def test_does_not_flag_clean_questions() -> None:
    """Founder D1/D2 (3.5-4/5): no lexical overlap with their answers."""
    assert stem_leak_reason(
        "Which insect is known for its impressive hunting success rate, "
        "capturing prey up to 97% of the time?",
        "Dragonfly",
    ) is None
    assert stem_leak_reason(
        "What is the name of the river flowing beneath the Amazon River?",
        "Hamza River",
    ) is None


def test_mcq_is_skipped() -> None:
    """MCQ stems legitimately carry option values ('...Snivy, Tepig, Oshawott,
    Pikachu?'); leak shapes there are distractor_quality's job."""
    assert stem_leak_reason(
        "Which of these is not a starter Pokemon: Snivy, Tepig, Oshawott, Pikachu?",
        "d",
        possible_answers={"a": "Snivy", "b": "Tepig", "c": "Oshawott", "d": "Pikachu"},
    ) is None


def test_multiword_answer_needs_majority_coverage() -> None:
    """One shared generic word out of several answer words is not a leak."""
    assert stem_leak_reason(
        "What prevents stomach acid from damaging our stomach lining?",
        "A protective mucus layer",
    ) is None


def test_gloss_words_do_not_leak() -> None:
    """2026-07-10 validation FP (founder Q13, 5/5): the answer's parenthetical
    gloss ('steps of a Roman soldier') shares words with the stem, but the
    gradable answer is just 'Paces' — the guard must judge the core only."""
    assert stem_leak_reason(
        "The English word 'mile' has been in use for over 2,000 years — and it "
        "carries the exact measurement of a Roman soldier. A thousand of what?",
        "Paces (steps of a Roman soldier)",
    ) is None


def test_choice_in_stem_is_not_a_leak() -> None:
    """2026-07-10 validation FPs (founder Q10/Q34): a stem that itself offers
    the alternatives necessarily contains the answer — that is the format."""
    assert stem_leak_reason(
        "Which appeared first: the Marvel superhero Black Panther, or the "
        "Black Panther political party?",
        "The superhero",
    ) is None
    assert stem_leak_reason(
        "Was Cleopatra closer in time to the construction of the pyramids, "
        "or the Moon landings?",
        "The Moon landings",
    ) is None


def test_shared_surname_half_coverage_passes() -> None:
    """2026-07-10 validation FP: 'What was Mickey Mouse's original name?' →
    'Mortimer Mouse'. The shared surname is the subject, not a giveaway —
    exactly half coverage must not flag (the distinctive token is unleaked)."""
    assert stem_leak_reason(
        "Walt Disney's wife convinced him to change Mickey Mouse's original "
        "name before his 1928 debut. What was it?",
        "Mortimer Mouse",
    ) is None


# --- long_answer_reason ---------------------------------------------------------


def test_flags_sentence_length_answer() -> None:
    """Founder Q35 (2/5) / Q9: explanation-sentence answers are ungradable by
    the voice grader — locked ruling 'answers stay a few words'."""
    assert long_answer_reason(
        "It melts just below human body temperature, which is why chocolate "
        "melts in your mouth"
    ) == "long_answer(7w)"


def test_short_and_glossed_answers_pass() -> None:
    """The gloss is post-answer context, not the spoken answer — 'Munitions
    and weapons (the Royal Arsenal armaments factory)' grades as 3 words."""
    assert long_answer_reason("Paces (steps of a Roman soldier)") is None
    assert long_answer_reason(
        "Munitions and weapons (the Royal Arsenal armaments factory in Woolwich)"
    ) is None
    assert long_answer_reason("The Moon landings") is None
    # Founder Q22 (5/5): the comma elaboration is context, not the answer.
    assert long_answer_reason(
        "Astronauts on the International Space Station, orbiting about 400 km overhead"
    ) is None


def test_long_answer_skips_mcq_and_tf() -> None:
    assert long_answer_reason("a", {"a": "Option one", "b": "Option two"}) is None
    assert long_answer_reason("True — he voiced Mickey for roughly twenty years") is None


# --- units_reason (#99 D3) ----------------------------------------------------


def test_flags_fahrenheit_answer_g3_q7() -> None:
    """G3 Q7 (founder 2026-07-15): '100 degrees Fahrenheit' — a Slovak player
    cannot convert imperial mid-quiz; °C must lead or accompany."""
    assert units_reason(
        "For the first time in over 300 years of weather observations, England "
        "recorded what round-number temperature milestone during a heat wave?",
        "100 degrees Fahrenheit",
    ) == "imperial_units(degrees fahrenheit)"


def test_flags_quantified_miles_g3_q9() -> None:
    """G3 Q9: 'never more than six miles from a body of water' — the same
    unusable-imperial defect, in the stem rather than the answer."""
    assert units_reason(
        "You're never more than six miles from a body of water in this U.S. "
        "state, which is also the only one made up of two peninsulas. Name it.",
        "Michigan",
    ) == "imperial_units(six miles)"


def test_iconic_figure_with_metric_companion_passes() -> None:
    """Rule 11's sanctioned shape: iconic source figure, metric alongside."""
    assert units_reason(
        "England's hottest day on record hit 40 °C (104 °F). True or false: "
        "that reading came in 2022?",
        "True",
    ) is None


def test_flags_imperial_in_mcq_options() -> None:
    """The guard reads option values too — an imperial-only option set is the
    same defect as an imperial-only answer."""
    assert units_reason(
        "Roughly how far can a dragonfly travel in a single hour?",
        "b",
        possible_answers={"a": "10 miles", "b": "30 miles", "c": "90 miles"},
    ) is not None


def test_unquantified_unit_words_do_not_flag() -> None:
    """Proper nouns and unit-less idioms must never fire: 'Miles' the name and
    body-part 'feet' carry no figure the player would have to convert."""
    assert units_reason(
        "Which jazz trumpeter recorded the album 'Kind of Blue'?",
        "Miles Davis",
    ) is None
    assert units_reason(
        "How many feet does a garden snail use to move around?",
        "One",
    ) is None


def test_metric_only_figures_pass() -> None:
    """The desired end state flags nothing."""
    assert units_reason(
        "A teaspoon of neutron star material weighs about a billion tonnes. "
        "True or false?",
        "True",
    ) is None
    assert units_reason(
        "Roughly how many kilometres of blood vessels are in a human body?",
        "About 100,000 km",
    ) is None


# --- undated_record_reason (#99 D2 subset, shadow-only) -------------------------


def test_flags_undated_record_g3_q7() -> None:
    """G3 Q7: a 'first time in over 300 years' milestone with no year/era —
    the founder's note was literally 'missing the measurement date'."""
    assert undated_record_reason(
        "For the first time in over 300 years of weather observations, England "
        "recorded what round-number temperature milestone during a heat wave?",
    ) == "undated_record(for the first time)"


def test_dated_record_passes() -> None:
    """A year anywhere in stem+explanation anchors the record."""
    assert undated_record_reason(
        "For the first time in over 300 years, England recorded a temperature "
        "milestone. What was it?",
        explanation="The 40 °C reading came during the July 2022 heat wave.",
    ) is None
    # Era words anchor too (rule 8 pushes exact years out of the stem).
    assert undated_record_reason(
        "In Victorian times, which record did the Great Eastern hold?",
    ) is None


def test_no_record_marker_is_silent() -> None:
    """No record/first/milestone claim → nothing to date."""
    assert undated_record_reason(
        "An octopus's beak is made of the same material as your fingernails. "
        "True or false?",
    ) is None


# --- true_false_key -----------------------------------------------------------


def test_true_false_detection_free_text_and_mcq() -> None:
    assert true_false_key("True") == "true"
    assert true_false_key(" false ") == "false"
    assert true_false_key("Loon") is None
    # Annotated T/F answers (separator required) are still T/F items…
    assert true_false_key("True — he voiced Mickey for ~20 years") == "true"
    assert true_false_key("False: it was never banned") == "false"
    # …but an answer merely *starting* with the word is not (no separator).
    assert true_false_key("True North") is None
    # MCQ shape: key letter resolved through the two T/F options.
    assert true_false_key("a", {"a": "True", "b": "False"}) == "true"
    # MCQ with non-T/F options is not a T/F question even if an option says True.
    assert true_false_key("a", {"a": "True", "b": "Maybe"}) is None


# --- tf_imbalance_excess ------------------------------------------------------


def test_flags_all_true_batch_excess_only() -> None:
    """The verified corpus defect (32/34 'True'): an all-true batch keeps the
    balanced allowance and flags the later excess, deterministically."""
    items = [(f"q{i}", "true") for i in range(5)]
    # ceil(0.6 * 5) = 3 allowed → q3, q4 are excess.
    assert tf_imbalance_excess(items) == ["q3", "q4"]


def test_balanced_and_small_batches_pass() -> None:
    # 3:2 split is within the 60% allowance.
    items = [("q0", "true"), ("q1", "false"), ("q2", "true"),
             ("q3", "false"), ("q4", "true")]
    assert tf_imbalance_excess(items) == []
    # Below the minimum count there is no distribution to judge.
    assert tf_imbalance_excess([("q0", "true"), ("q1", "true"), ("q2", "true")]) == []
    assert tf_imbalance_excess([]) == []
