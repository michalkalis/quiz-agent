"""Pattern → question_type routing tests (issue #42 task 42.8).

Why these scenarios:

- Each MCQ-routed pattern is asserted by name so that silently
  renaming a pattern in the generator (or dropping one from
  ``PATTERNS_TO_MCQ``) trips this test. The set is small but it is
  the contract between the LLM's pattern labels and the post-gen
  type-tagging step in ``GenerationStage`` (42.9a) — drift here
  silently downgrades MCQ-shaped questions to free-form text.
- Non-mapped patterns must return ``"text"`` (not raise) because the
  generator emits many patterns we don't MCQ-ify (``open_question``,
  ``causal``, etc.); they all belong in the free-form path.
- ``None`` / empty string are explicit cases — the generator's
  pattern field is best-effort and may be missing on legacy fixtures
  or model output; the helper must degrade to ``"text"``, not crash.
- The Pydantic ``Question.type`` validator is asserted with the exact
  trailing-space typo called out in the issue plan (42.8) because a
  whitespace-tolerant ``str`` field is what allowed the original
  Motivation §5 bug to be even *possible* — the regression test is
  precisely "trailing space fails loud".
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.generation.pattern_routing import (
    PATTERNS_TO_MCQ,
    choose_question_type,
)
from quiz_shared.models.question import Question


class TestChooseQuestionType:
    @pytest.mark.parametrize(
        "pattern",
        sorted(PATTERNS_TO_MCQ),
    )
    def test_mcq_patterns_route_to_text_multichoice(self, pattern: str) -> None:
        assert choose_question_type(pattern) == "text_multichoice"

    @pytest.mark.parametrize(
        "pattern",
        [
            "open_question",
            "causal",
            "definition",
            "list",
            "unknown_pattern",
        ],
    )
    def test_non_mcq_patterns_route_to_text(self, pattern: str) -> None:
        assert choose_question_type(pattern) == "text"

    def test_none_pattern_routes_to_text(self) -> None:
        assert choose_question_type(None) == "text"

    def test_empty_string_routes_to_text(self) -> None:
        assert choose_question_type("") == "text"

    def test_expected_mcq_patterns_present(self) -> None:
        # Lock the set membership so accidental removals fail the test
        # rather than silently disabling MCQ routing for that pattern.
        assert PATTERNS_TO_MCQ == frozenset(
            {
                "true_false",
                "odd_one_out",
                "comparison_bet_older_larger",
                "year_guess",
            }
        )


def _base_question_kwargs(**overrides) -> dict:
    base = dict(
        id="q_test_routing",
        question="Is the sky blue?",
        correct_answer="Yes",
        topic="Science",
        category="adults",
        difficulty="easy",
    )
    base.update(overrides)
    return base


class TestQuestionTypeValidator:
    @pytest.mark.parametrize(
        "qtype",
        ["text", "text_multichoice", "audio", "image", "video"],
    )
    def test_allowed_types_construct(self, qtype: str) -> None:
        q = Question(**_base_question_kwargs(type=qtype))
        assert q.type == qtype

    def test_trailing_space_typo_raises(self) -> None:
        with pytest.raises(ValidationError):
            Question(**_base_question_kwargs(type="text_multichoice "))

    def test_unknown_type_raises(self) -> None:
        with pytest.raises(ValidationError):
            Question(**_base_question_kwargs(type="multiple_choice"))

    def test_empty_type_raises(self) -> None:
        with pytest.raises(ValidationError):
            Question(**_base_question_kwargs(type=""))
