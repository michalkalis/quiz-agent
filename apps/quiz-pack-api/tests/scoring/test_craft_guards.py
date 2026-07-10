"""Unit tests for the deterministic craft guards (#72 reviewer upgrade).

Why these scenarios: the guards encode the founder's calibration ground truth
(2026-07-09/10). Every positive case is a question class the founder penalised
live; every negative case is a question the founder rated 4-5/5 — a guard that
flags those would silently delete exactly the questions we want, so the
false-positive cases are the load-bearing half of this file.
"""

from __future__ import annotations

from app.scoring.craft_guards import (
    stem_leak_reason,
    tf_imbalance_excess,
    true_false_key,
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


# --- true_false_key -----------------------------------------------------------


def test_true_false_detection_free_text_and_mcq() -> None:
    assert true_false_key("True") == "true"
    assert true_false_key(" false ") == "false"
    assert true_false_key("Loon") is None
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
