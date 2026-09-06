"""#168 — batch translation pipeline SK/CS, T7: the DD13 delta answerability check.

The whole point of the control leg is attribution: a blind model failing a
question proves nothing about the translation unless the same model passed the
English source. These tests pin the three verdicts that decision rests on —
a real flip blocks approval, a control failure never blames (or drops) an
EN-approved question, and a missing judgment leaves the row pending, because
for a GATE the fail-safe direction inverts: absence of a verdict is not an
approval.

They also pin the SK/CS comparison, which is why the check could not simply
reuse the English checker: its normalizer deletes diacritics instead of folding
them, so every accented Slovak answer would read as a wrong answer.
"""

from __future__ import annotations

import json
from typing import Any, Optional

import pytest

from app.translation_verification.answerability import (
    DeltaAnswerabilityChecker,
    _resolve_option_key,
    _text_answer_matches,
)
from app.translation_verification.draft import TranslatedDraft
from quiz_shared.models.question import Question

_EN_MARKER = "You are a strong quiz player"


def _question(**overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id="q_1",
        question="Which spice was traded for Manhattan?",
        correct_answer="Nutmeg",
        topic="History",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _draft(**overrides: Any) -> TranslatedDraft:
    base: dict[str, Any] = dict(
        question="Ktoré korenie sa vymenilo za Manhattan?",
        correct_answer="Muškátový oriešok",
    )
    base.update(overrides)
    return TranslatedDraft(**base)


def _checker(en: Optional[str], target: Optional[str]) -> DeltaAnswerabilityChecker:
    """One stub LLM boundary for both legs — same model, same settings."""
    checker = DeltaAnswerabilityChecker(model="stub-model")
    prompts: list[str] = []

    async def _complete(prompt: str) -> Optional[str]:
        prompts.append(prompt)
        return en if _EN_MARKER in prompt else target

    checker._checker._complete = _complete  # type: ignore[method-assign]
    checker.prompts = prompts  # type: ignore[attr-defined]
    return checker


def _reply(answer: str, **extra: Any) -> str:
    fields = {"answer": answer, "gave_up": False, "issue": None, **extra}
    return json.dumps(fields, ensure_ascii=False)


# --- the three DD13 verdicts ---------------------------------------------------


@pytest.mark.asyncio
async def test_en_pass_target_fail_blocks_approval() -> None:
    """EN passed, SK failed → the translation is what changed. Critical."""
    checker = _checker(en=_reply("Nutmeg"), target=_reply("Škorica"))
    result = await checker.check(_question(), _draft(), "sk")

    assert result.verdict == "translation_flip"
    assert result.blocks_approval is True
    assert result.en.passed and not result.target.passed
    # Both legs persisted, so a later re-tune can re-score without re-calling.
    payload = result.to_verification_json()
    assert payload["en"]["answer"] == "Nutmeg"
    assert payload["target"]["answer"] == "Škorica"
    assert payload["model"] == "stub-model" and payload["checked_at"]


@pytest.mark.asyncio
async def test_control_fail_does_not_blame_translation() -> None:
    """The model just cannot answer this one — in English either."""
    checker = _checker(en=_reply("Cinnamon"), target=_reply("Muškátový oriešok"))
    result = await checker.check(_question(), _draft(), "sk")

    assert result.verdict == "control_fail"
    assert result.blocks_approval is False


@pytest.mark.asyncio
async def test_unavailable_leaves_row_pending() -> None:
    """No verdict is not an approval: for a gate the fail-safe inverts."""
    checker = _checker(en=_reply("Nutmeg"), target="upstream 502, no JSON here")
    result = await checker.check(_question(), _draft(), "sk")

    assert result.verdict == "unavailable"
    assert result.blocks_approval is True
    assert result.target.reason == "check_unavailable"


@pytest.mark.asyncio
async def test_both_legs_failing_is_not_a_translation_defect() -> None:
    checker = _checker(en=_reply("Cinnamon"), target=_reply("Škorica"))
    result = await checker.check(_question(), _draft(), "sk")
    assert result.verdict == "control_fail" and result.blocks_approval is False


@pytest.mark.asyncio
async def test_en_control_unavailable_also_leaves_row_pending() -> None:
    checker = _checker(en=None, target=_reply("Muškátový oriešok"))
    result = await checker.check(_question(), _draft(), "sk")
    assert result.verdict == "unavailable" and result.blocks_approval is True


@pytest.mark.asyncio
async def test_target_leg_gives_up_is_a_flip_not_an_unavailable() -> None:
    """An explicit surrender is a considered judgment, unlike a dead call."""
    checker = _checker(en=_reply("Nutmeg"), target=_reply("", gave_up=True))
    result = await checker.check(_question(), _draft(), "sk")
    assert result.verdict == "translation_flip"
    assert result.target.reason == "unanswerable"


@pytest.mark.asyncio
async def test_target_leg_ambiguity_flag_is_a_flip() -> None:
    checker = _checker(
        en=_reply("Nutmeg"), target=_reply("Muškátový oriešok", issue="ambiguous")
    )
    result = await checker.check(_question(), _draft(), "sk")
    assert result.verdict == "translation_flip"
    assert result.target.reason == "flagged_ambiguous"


# --- prompt + comparison -------------------------------------------------------


@pytest.mark.asyncio
async def test_target_prompt_is_localized_and_asks_for_the_target_language() -> None:
    checker = _checker(en=_reply("Nutmeg"), target=_reply("Muškátový oriešok"))
    await checker.check(_question(), _draft(), "sk")

    en_prompt, sk_prompt = checker.prompts  # type: ignore[attr-defined]
    assert _EN_MARKER in en_prompt and _question().question in en_prompt
    assert "po slovensky" in sk_prompt and _draft().question in sk_prompt
    # Same JSON contract in both legs — the parser is shared.
    assert '"gave_up"' in sk_prompt and '"issue"' in sk_prompt


@pytest.mark.asyncio
async def test_unsupported_language_fails_loud() -> None:
    checker = _checker(en=_reply("Nutmeg"), target=_reply("Muskatnuss"))
    with pytest.raises(ValueError):
        await checker.check(_question(), _draft(), "de")


@pytest.mark.asyncio
async def test_mcq_leg_compares_the_resolved_option_key() -> None:
    """DD3 stores correct_answer_key; comparing keys removes the text noise."""
    source = _question(
        possible_answers={"a": "Nutmeg", "b": "Cinnamon"}, correct_answer="Nutmeg"
    )
    draft = _draft(
        possible_answers={"a": "Muškátový oriešok", "b": "Škorica"},
        correct_answer="Muškátový oriešok",
        correct_answer_key="a",
    )
    passing = _checker(en=_reply("a"), target=_reply("a"))
    assert (await passing.check(source, draft, "sk")).verdict == "pass"

    flipping = _checker(en=_reply("a"), target=_reply("b"))
    assert (await flipping.check(source, draft, "sk")).verdict == "translation_flip"


def test_option_key_resolves_from_letter_or_from_option_text() -> None:
    options = {"a": "Muškátový oriešok", "b": "Škorica"}
    assert _resolve_option_key("a", options) == "a"
    # Accent-folded, so an answer typed without diacritics still resolves.
    assert _resolve_option_key("muskatovy oriesok", options) == "a"
    assert _resolve_option_key("Pepper", options) is None


def test_text_match_folds_diacritics_instead_of_deleting_the_letter() -> None:
    """The EN normalizer would turn "žirafa" into "irafa" and never match."""
    assert _text_answer_matches("zirafa", ["Žirafa"])
    assert _text_answer_matches("Muškátový oriešok", ["muskatovy oriesok"])
    assert not _text_answer_matches("Škorica", ["Muškátový oriešok"])


def test_text_match_accepts_a_translated_alternate_answer() -> None:
    assert _text_answer_matches("muškátový orech", ["Muškátový oriešok", "muškátový orech"])
