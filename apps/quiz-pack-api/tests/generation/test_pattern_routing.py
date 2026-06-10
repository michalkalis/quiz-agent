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
    answer_shape,
    choose_question_type,
    verification_mode,
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

    # 42.20 BLOCKER (2026-06-10): first live batch emitted Pattern Library
    # title-derived labels with a `the_` prefix; exact matching routed all
    # of them to "text", so 42.9a's MCQ tagging fired zero times. These are
    # the four labels observed live — `the_odd_one_out` must route to MCQ,
    # the rest stay free-form.
    @pytest.mark.parametrize(
        ("pattern", "expected"),
        [
            ("the_odd_one_out", "text_multichoice"),
            ("the_surprising_connection", "text"),
            ("the_hidden_property", "text"),
            ("the_scale_surprise", "text"),
        ],
    )
    def test_live_observed_the_prefixed_labels(
        self, pattern: str, expected: str
    ) -> None:
        assert choose_question_type(pattern) == expected

    def test_title_case_label_routes_via_normalization(self) -> None:
        # Free-text Pattern Library title form, not snake_case.
        assert choose_question_type("The Odd One Out") == "text_multichoice"
        assert choose_question_type("True False") == "text_multichoice"

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


class TestAnswerShape:
    """Issue #46 46.B1 — answer_shape routes by question shape, not number.

    Why these scenarios:
    - Open-shape patterns (free-text *and* snake_case forms, since the
      generator emits both) must classify ``"open"`` so they divert to the
      open-branch prompt; a normalization regression here would silently
      send mechanism/puzzle questions through Track A's short-answer drop.
    - "Why/how-does/what-would-happen" framings classify ``"open"`` from
      the text alone — the issue's two open examples ("Why are Ferraris
      red?", "What happens when the Sun goes out?") must NOT be treated as
      closed and have their sentence answers truncated.
    - Quantitative "how many/old/far" and the closed patterns enumerated in
      D1 (Comparison Bet, Estimation, Odd-One-Out, True/False) must stay
      ``"closed"`` — they have short answers and Track A keeps them short.
    - ``None`` / empty / unknown fail-safe to ``"closed"`` (D1): a weak
      signal keeps short-answer enforcement rather than granting the
      sentence-answer exception.
    """

    @pytest.mark.parametrize(
        "pattern",
        [
            "open_question",
            "causal",
            "lateral_thinking",
            "lateral_thinking_puzzle",
            "Lateral Thinking Puzzle",
            "lateral_puzzle",
        ],
    )
    def test_open_patterns_are_open(self, pattern: str) -> None:
        assert answer_shape(pattern, "Some setup.") == "open"

    @pytest.mark.parametrize(
        "question_text",
        [
            "Why are Ferraris red?",
            "What happens when the Sun goes out?",
            "How does a transistor amplify a signal?",
            "What would happen if the Earth stopped spinning?",
        ],
    )
    def test_open_framing_text_is_open(self, question_text: str) -> None:
        # No pattern hint — the open framing alone must route to open.
        assert answer_shape(None, question_text) == "open"

    @pytest.mark.parametrize(
        "question_text",
        [
            "How many moons does Jupiter have?",
            "How old is the Great Barrier Reef?",
            "How far is the Moon from Earth?",
            "Which planet is closest to the Sun?",
        ],
    )
    def test_quantitative_and_factual_text_is_closed(
        self, question_text: str
    ) -> None:
        assert answer_shape(None, question_text) == "closed"

    @pytest.mark.parametrize(
        "pattern",
        [
            "comparison_bet_older_larger",
            "odd_one_out",
            "true_false",
            "year_guess",
            "number_sequence",
            "estimation",
        ],
    )
    def test_closed_patterns_are_closed(self, pattern: str) -> None:
        assert answer_shape(pattern, "Which is older, A or B?") == "closed"

    @pytest.mark.parametrize("pattern", [None, "", "unknown_pattern"])
    def test_fail_safe_to_closed(self, pattern) -> None:
        assert answer_shape(pattern, "What is the capital of France?") == "closed"


class TestVerificationMode:
    """Issue #46 46.B1 — verification_mode isolates lateral puzzles (D2/R2).

    Why these scenarios:
    - Only pure lateral-thinking puzzles classify ``"logical"`` (no web
      source exists → LogicalConsistencyVerifier). Factual-mechanism open
      questions ("Why are Ferraris red?", ``causal``/``open_question``) must
      stay ``"factual"`` because they ARE web-verifiable — misrouting them
      to the logical judge would skip the source check that catches errors.
    - Everything fail-safes to ``"factual"`` (R2): a mislabelled question
      keeps web verification rather than silently bypassing FactVerifier.
    """

    @pytest.mark.parametrize(
        "pattern",
        ["lateral_thinking", "lateral_thinking_puzzle", "Lateral Thinking Puzzle"],
    )
    def test_lateral_puzzles_are_logical(self, pattern: str) -> None:
        assert verification_mode(pattern, "A man lies dead in a field.") == "logical"

    @pytest.mark.parametrize(
        "pattern",
        ["causal", "open_question"],
    )
    def test_factual_mechanism_open_patterns_stay_factual(
        self, pattern: str
    ) -> None:
        assert verification_mode(pattern, "Why are Ferraris red?") == "factual"

    @pytest.mark.parametrize("pattern", [None, "", "true_false", "unknown_pattern"])
    def test_fail_safe_to_factual(self, pattern) -> None:
        assert verification_mode(pattern, "Why are Ferraris red?") == "factual"


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
