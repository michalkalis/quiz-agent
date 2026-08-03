"""#135 D10 — round-trip answerability checker.

The checker is the early gate against unclear/ambiguous/dead-end questions:
a cheap model answers blind, and a miss (or the model's own unclear flag)
drops the question before it pays for verification and judging. These tests
pin the three behaviours the pipeline relies on: (1) the fail-safe — a dead
or unparseable checker KEEPS the question; (2) the comparison semantics —
lenient for text (paraphrase/containment), option-identity for MCQ, and
signal-only for open shapes; (3) the drop reasons the stage logs.
"""

from __future__ import annotations

from typing import Any, Optional

import pytest

from app.verification.answerability import (
    AnswerabilityChecker,
    _mcq_answers_match,
    _text_answers_match,
)
from quiz_shared.models.question import GenerationProvenance, Question


def _question(**overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id="q_1",
        question="Which spice was traded for Manhattan?",
        correct_answer="Nutmeg",
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _checker_returning(raw: Optional[str]) -> AnswerabilityChecker:
    checker = AnswerabilityChecker(model="stub-model")

    async def _complete(prompt: str) -> Optional[str]:
        checker.last_prompt = prompt  # type: ignore[attr-defined]
        return raw

    checker._complete = _complete  # type: ignore[method-assign]
    return checker


# --- comparison semantics -----------------------------------------------------


def test_text_match_tolerates_articles_case_and_containment() -> None:
    assert _text_answers_match("the nutmeg", ["Nutmeg"])
    assert _text_answers_match("Nutmeg (a spice)", ["nutmeg"])
    assert not _text_answers_match("Cinnamon", ["Nutmeg"])


def test_text_match_accepts_token_overlap_paraphrase() -> None:
    # Model paraphrases a multi-word answer — enough content-token overlap
    # must pass, or every phrased-differently correct answer becomes a drop.
    assert _text_answers_match(
        "the International Space Station", ["International Space Station (ISS)"]
    )


def test_mcq_match_resolves_letter_and_text_picks() -> None:
    options = {"a": "Nearest landmass", "b": "International Space Station"}
    correct = "International Space Station"
    assert _mcq_answers_match("b", options, correct)
    assert _mcq_answers_match("International Space Station", options, correct)
    assert not _mcq_answers_match("a", options, correct)


# --- checker verdicts ---------------------------------------------------------


@pytest.mark.asyncio
async def test_checker_fail_safe_keeps_question_when_call_or_parse_fails() -> None:
    # Dead call, non-JSON, JSON of a different shape (a hermetic-test mock's
    # canned payload), or an empty answer without an explicit gave_up — all
    # mean "no verdict", never "failed verdict".
    for raw in (
        None,
        "no json here",
        '{"questions": [{"question": "canned mock"}]}',
        '{"answer": "", "gave_up": false, "issue": null}',
    ):
        result = await _checker_returning(raw).check(_question())
        assert result.passed is True, raw
        assert result.reason == "check_unavailable"


@pytest.mark.asyncio
async def test_checker_passes_on_correct_blind_answer() -> None:
    checker = _checker_returning('{"answer": "nutmeg", "gave_up": false, "issue": null}')
    result = await checker.check(_question())
    assert result.passed is True


@pytest.mark.asyncio
async def test_checker_drops_on_wrong_answer_gave_up_and_unclear_flag() -> None:
    cases = [
        ('{"answer": "cinnamon", "gave_up": false, "issue": null}', "wrong_answer"),
        ('{"answer": "", "gave_up": true, "issue": null}', "unanswerable"),
        ('{"answer": "nutmeg", "gave_up": false, "issue": "ambiguous"}', "flagged_ambiguous"),
    ]
    for raw, expected_reason in cases:
        result = await _checker_returning(raw).check(_question())
        assert result.passed is False, raw
        assert result.reason == expected_reason


@pytest.mark.asyncio
async def test_checker_renders_mcq_options_into_the_blind_prompt() -> None:
    checker = _checker_returning('{"answer": "b", "gave_up": false, "issue": null}')
    q = _question(
        type="text_multichoice",
        possible_answers={"a": "Nearest landmass", "b": "International Space Station"},
        correct_answer="International Space Station",
    )
    result = await checker.check(q)
    assert result.passed is True
    assert "OPTIONS: a) Nearest landmass | b) International Space Station" in (
        checker.last_prompt  # type: ignore[attr-defined]
    )


@pytest.mark.asyncio
async def test_open_shape_ignores_answer_mismatch_but_honours_flags() -> None:
    # Sentence answers can't be fuzzy-matched; only the model's own signals
    # count for open shapes.
    open_q = _question(
        question="Why do mountain climbers wear dark sunglasses on grey days?",
        correct_answer="Snow reflects UV light strongly even under clouds",
        generation_metadata=GenerationProvenance(reasoning_pattern="open_question"),
    )
    mismatch = _checker_returning(
        '{"answer": "something entirely different", "gave_up": false, "issue": null}'
    )
    assert (await mismatch.check(open_q)).passed is True

    flagged = _checker_returning(
        '{"answer": "glare", "gave_up": false, "issue": "unclear"}'
    )
    result = await flagged.check(open_q)
    assert result.passed is False
    assert result.reason == "flagged_unclear"
