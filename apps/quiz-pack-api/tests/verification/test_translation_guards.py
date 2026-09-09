"""#168 — batch translation pipeline SK/CS, T6: deterministic translation guards.

These guards are the cheap half of the gate: they check invariants a
translation cannot break and still be the same question, so every one of them
must both (a) stay silent on a correct Slovak translation and (b) speak up on
the concrete defect it exists for. The defects are real ones from the SK
reference set (truncation, untranslated True/False options, dropped figures) —
a guard that cannot fail on those is decoration.

The enforcement test matters most: craft guards have a shadow/enforce dial
because they score taste; these check invariants, so ``CRAFT_GUARDS_ENFORCE``
must have no say — a drafted question that loses a year is wrong whatever the
scoring pipeline's flag says.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.translation_verification.draft import TranslatedDraft
from app.translation_verification.guards import (
    length_ratio_reason,
    mcq_shape_reason,
    number_preservation_reason,
    placeholder_integrity_reason,
    run_guards,
    script_integrity_reason,
    unit_preservation_reason,
    untranslated_string_reason,
)
from quiz_shared.models.question import Question


def _question(**overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id="q_1",
        question="In which year did the Apollo 11 crew first walk on the Moon?",
        correct_answer="1969",
        topic="History",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _draft(**overrides: Any) -> TranslatedDraft:
    base: dict[str, Any] = dict(
        question="V ktorom roku sa posádka Apolla 11 prvýkrát prešla po Mesiaci?",
        correct_answer="1969",
    )
    base.update(overrides)
    return TranslatedDraft(**base)


# --- 1. number / date preservation --------------------------------------------


def test_number_guard_passes_on_preserved_figures_and_sk_formatting() -> None:
    # "1,500" → "1 500" is Slovak number formatting, not a lost figure.
    source = _question(question="How tall is the tower, 1,500 feet or 1,600?")
    draft = _draft(question="Aká vysoká je veža, 1 500 stôp alebo 1 600?")
    assert number_preservation_reason(source, draft, "sk") is None


def test_number_guard_flags_a_year_that_changed_in_translation() -> None:
    # A transposed year survives every fluency check but breaks the answer.
    draft = _draft(
        question="V ktorom roku sa posádka Apolla 11 prvýkrát prešla po Mesiaci?",
        correct_answer="1996",
    )
    reason = number_preservation_reason(_question(), draft, "sk")
    assert reason is not None and "1969" in reason


def test_number_guard_allows_a_century_ordinal_the_idiom_requires() -> None:
    # "the 1930s" is "v 30. rokoch 20. storočia": the 20 is the idiom, not an
    # invented figure. A genuinely new figure still blocks.
    source = _question(question="When the dam was built in the 1930s, how long did it take?")
    draft = _draft(question="Keď sa priehrada stavala v 30. rokoch 20. storočia, ako dlho to trvalo?")
    assert number_preservation_reason(source, draft, "sk") is None
    czech = _draft(question="Když se přehrada stavěla ve 30. letech 20. století, jak dlouho to trvalo?")
    assert number_preservation_reason(source, czech, "cs") is None
    invented = _draft(question="Keď sa priehrada stavala v 30. rokoch, trvalo to 5 rokov?")
    assert "added=5" in (number_preservation_reason(source, invented, "sk") or "")


# --- 2. unit preservation ------------------------------------------------------


def test_unit_guard_passes_when_symbol_units_survive() -> None:
    source = _question(question="What boils at 100 °C at sea level?")
    draft = _draft(question="Čo vrie pri 100 °C na úrovni mora?")
    assert unit_preservation_reason(source, draft, "sk") is None


def test_unit_guard_flags_a_dropped_unit_symbol() -> None:
    # "100 °C" → "100" leaves the answer ambiguous in the target language.
    source = _question(question="What boils at 100 °C at sea level?")
    draft = _draft(question="Čo vrie pri 100 na úrovni mora?")
    assert unit_preservation_reason(source, draft, "sk") == "unit_dropped(°c)"


def test_unit_guard_flags_a_silent_imperial_to_metric_conversion() -> None:
    # Converting the figure is a content change wearing a translation's clothes.
    source = _question(question="Water boils at 212 degrees Fahrenheit — true?")
    draft = _draft(question="Voda vrie pri 100 stupňoch Celsius — je to pravda?")
    assert (
        unit_preservation_reason(source, draft, "sk")
        == "unit_system_converted(imperial_to_metric)"
    )


# --- 3. untranslated string ----------------------------------------------------


def test_untranslated_guard_passes_on_a_real_translation() -> None:
    assert untranslated_string_reason(_question(), _draft(), "sk") is None


def test_untranslated_guard_flags_english_returned_verbatim() -> None:
    source = _question()
    draft = _draft(question=source.question)
    assert untranslated_string_reason(source, draft, "sk") == (
        "untranslated_string(question)"
    )


def test_untranslated_guard_skips_language_dependent_questions() -> None:
    # Wordplay items are excluded from non-EN serving anyway; an English
    # fragment inside one can be the point, so the guard must not fire.
    source = _question(language_dependent=True)
    draft = _draft(question=source.question)
    assert untranslated_string_reason(source, draft, "sk") is None


# --- 4. MCQ shape --------------------------------------------------------------


_OPTIONS_EN = {"a": "Nutmeg", "b": "Cinnamon", "c": "Pepper", "d": "Clove"}
_OPTIONS_SK = {"a": "Muškátový oriešok", "b": "Škorica", "c": "Korenie", "d": "Klinček"}


def test_mcq_guard_passes_on_matching_shape_with_resolvable_key() -> None:
    source = _question(possible_answers=_OPTIONS_EN, correct_answer="Nutmeg")
    draft = _draft(
        possible_answers=_OPTIONS_SK,
        correct_answer="Muškátový oriešok",
        correct_answer_key="a",
    )
    assert mcq_shape_reason(source, draft, "sk") is None


def test_mcq_guard_flags_a_dropped_option() -> None:
    source = _question(possible_answers=_OPTIONS_EN, correct_answer="Nutmeg")
    draft = _draft(
        possible_answers={k: v for k, v in _OPTIONS_SK.items() if k != "d"},
        correct_answer="Muškátový oriešok",
        correct_answer_key="a",
    )
    reason = mcq_shape_reason(source, draft, "sk")
    assert reason is not None and reason.startswith("mcq_shape(option_keys_changed")


def test_mcq_guard_flags_two_options_that_collapsed_to_one_word() -> None:
    # A translation that renders two distinct options identically makes the
    # question unanswerable — two options are then equally correct.
    source = _question(possible_answers=_OPTIONS_EN, correct_answer="Nutmeg")
    collapsed = dict(_OPTIONS_SK, c="Škorica")
    draft = _draft(
        possible_answers=collapsed,
        correct_answer="Muškátový oriešok",
        correct_answer_key="a",
    )
    reason = mcq_shape_reason(source, draft, "sk")
    assert reason is not None and reason.startswith("mcq_shape(duplicate_option")


def test_mcq_guard_flags_an_unresolvable_correct_answer_key() -> None:
    source = _question(possible_answers=_OPTIONS_EN, correct_answer="Nutmeg")
    draft = _draft(
        possible_answers=_OPTIONS_SK,
        correct_answer="Muškátový oriešok",
        correct_answer_key="e",
    )
    assert mcq_shape_reason(source, draft, "sk") == (
        "mcq_shape(correct_answer_key_unresolvable:e)"
    )


# --- 5. placeholder / markup integrity -----------------------------------------


def test_placeholder_guard_passes_when_markup_is_carried_over() -> None:
    source = _question(question="Who said <i>veni, vidi, vici</i> in {year}?")
    draft = _draft(question="Kto povedal <i>veni, vidi, vici</i> v roku {year}?")
    assert placeholder_integrity_reason(source, draft, "sk") is None


def test_placeholder_guard_flags_a_translated_placeholder() -> None:
    # A translator that localizes the placeholder itself breaks formatting.
    source = _question(question="Who said this in {year}, according to Suetonius?")
    draft = _draft(question="Kto to podľa Suetonia povedal v roku {rok}?")
    reason = placeholder_integrity_reason(source, draft, "sk")
    assert reason is not None and "{year}" in reason and "{rok}" in reason


# --- 6. length ratio -----------------------------------------------------------


def test_length_ratio_guard_passes_on_normal_slovak_expansion() -> None:
    assert length_ratio_reason(_question(), _draft(), "sk") is None


def test_length_ratio_guard_flags_a_truncated_translation() -> None:
    # The real SK defect: a full question came back as a two-word fragment.
    draft = _draft(question="Suchý bodliak")
    reason = length_ratio_reason(_question(), draft, "sk")
    assert reason is not None and reason.startswith("length_ratio(question=")


# --- enforcement ---------------------------------------------------------------


@pytest.mark.parametrize("enforce", ["0", "1", "false", "true"])
def test_guards_enforce_regardless_of_craft_guards_enforce(
    monkeypatch: pytest.MonkeyPatch, enforce: str
) -> None:
    """CRAFT_GUARDS_ENFORCE dials taste scoring; it may not dial invariants."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", enforce)
    draft = _draft(correct_answer="1996", question="Suchý bodliak")
    reasons = run_guards(_question(), draft, "sk")
    assert any(r.startswith("number_mismatch") for r in reasons)
    assert any(r.startswith("length_ratio") for r in reasons)


def test_run_guards_returns_empty_for_a_clean_draft() -> None:
    assert run_guards(_question(), _draft(), "sk") == []


# --- 7. script integrity -------------------------------------------------------


def test_script_guard_rejects_a_cyrillic_homoglyph_the_source_did_not_carry() -> None:
    # First prod smoke (2026-09-10): "hore" with a Cyrillic "е" — invisible on
    # screen, mispronounced by TTS, and never equal to the Latin word.
    source = _question(explanation="The material is hot at the top.")
    draft = _draft(explanation="Materiál je hor\u0435 horúci.")
    reason = script_integrity_reason(source, draft, "sk")
    assert reason is not None and "CYRILLIC SMALL LETTER IE" in reason
    assert "script_integrity" in "".join(run_guards(source, draft, "sk"))


def test_script_guard_allows_letters_the_source_carries() -> None:
    # A Greek letter in the English source is content, not a homoglyph.
    source = _question(question="Which constant is written as π?")
    draft = _draft(question="Ktorá konštanta sa zapisuje ako π?")
    assert script_integrity_reason(source, draft, "sk") is None
