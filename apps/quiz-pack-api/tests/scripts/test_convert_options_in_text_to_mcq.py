"""Tests for `scripts/convert_options_in_text_to_mcq.py` (Issue #42 task 42.11).

Why these tests matter:
- The script mutates committed data on disk, so idempotency (re-runs are
  no-ops) is the load-bearing property — verified end-to-end via
  ``process_file`` against a tmp file.
- The matcher must never pick an arbitrary option when the answer is
  ambiguous; otherwise we would silently corrupt MCQ correctness. The
  ``test_ambiguous_substring_skipped`` case pins that contract.
- Converted records must round-trip through the ``Question`` Pydantic model
  with ``type=text_multichoice``; the integration test (42.11 acceptance)
  asserts this.
"""

from __future__ import annotations

import json
from pathlib import Path

from quiz_shared.models.question import Question

from scripts.convert_options_in_text_to_mcq import (
    convert_question_inplace,
    find_matching_option,
    parse_options,
    process_file,
)


class TestParseOptions:
    def test_three_options_comma_or(self):
        assert parse_options("2 billion, 200 billion, or 20 quadrillion") == [
            "2 billion",
            "200 billion",
            "20 quadrillion",
        ]

    def test_two_options_or(self):
        assert parse_options("Egypt or Sudan") == ["Egypt", "Sudan"]

    def test_no_options(self):
        assert parse_options("just one thing") is None

    def test_empty(self):
        assert parse_options("") is None

    def test_five_options(self):
        # Real shape from claude_batch_005.json (flightless-bird odd-one-out).
        assert parse_options("Ostrich, Emu, Kiwi, Penguin, or Flamingo") == [
            "Ostrich",
            "Emu",
            "Kiwi",
            "Penguin",
            "Flamingo",
        ]

    def test_rejects_option_with_internal_em_dash(self):
        # Dr.-Seuss-style false positive: regex grabbed the wrong colon and
        # one "option" is a 50-word phrase ending in "— 50".
        long_first = (
            "write an entire children's book using no more than a certain "
            "number of different words. How many was the limit — 50"
        )
        assert parse_options(f"{long_first}, 100, or 200") is None

    def test_rejects_overly_long_option(self):
        long_opt = "x" * 70
        assert parse_options(f"{long_opt}, short, or other") is None

    def test_rejects_option_with_period(self):
        # A `.` inside an option signals a captured sentence boundary.
        assert parse_options("First. then more, second, or third") is None


class TestFindMatchingOption:
    OPTIONS = ["2 billion", "200 billion", "20 quadrillion"]

    def test_exact_match(self):
        assert find_matching_option("20 quadrillion", self.OPTIONS) == 2

    def test_case_and_article_normalised(self):
        # "the Atacama Desert" should match option "the Atacama Desert" or bare
        # "Atacama Desert" — articles are stripped during normalisation.
        opts = ["the Sahara", "the Atacama Desert", "Antarctica"]
        assert find_matching_option("Atacama Desert", opts) == 1
        assert find_matching_option("the Atacama Desert", opts) == 1

    def test_substring_via_alternative_answers(self):
        # "20 quadrillion ants" doesn't equal any option but uniquely contains
        # one — should resolve via substring.
        assert (
            find_matching_option("20 quadrillion ants", self.OPTIONS)
            == 2
        )

    def test_ambiguous_substring_skipped(self):
        # The answer "billion" substring-matches both options 0 and 1 — must
        # NOT silently pick one. This is the load-bearing safety contract.
        opts = ["2 billion", "200 billion", "20 quadrillion"]
        assert find_matching_option("billion", opts) is None

    def test_digit_substring_does_not_match(self):
        # Sequence-completion false positive guard: answer "216" must NOT
        # match option "1" just because "1" is a substring of "216". Word
        # boundaries fix this.
        opts = ["1", "8", "27", "64", "125", "___"]
        assert find_matching_option("216", opts) is None

    def test_no_match_returns_none(self):
        assert find_matching_option("nope", self.OPTIONS) is None

    def test_uses_alternative_answers_when_correct_fails(self):
        # Real shape: correct_answer is the full phrase, alt_answers has the
        # short form that matches the option.
        opts = ["Egypt", "Sudan"]
        assert (
            find_matching_option(
                "Sudan, with over 200 pyramids", opts, ["Sudan"]
            )
            == 1
        )


class TestConvertQuestionInplace:
    def _q(self, **overrides):
        base = {
            "id": "test-1",
            "question": "How many ants live on Earth: 2 billion, 200 billion, or 20 quadrillion?",
            "type": "text",
            "correct_answer": "20 quadrillion",
            "possible_answers": None,
            "alternative_answers": [],
        }
        base.update(overrides)
        return base

    def test_basic_conversion(self):
        q = self._q()
        rec = convert_question_inplace(q)
        assert rec is not None
        assert q["type"] == "text_multichoice"
        assert q["correct_answer"] == "c"
        assert q["possible_answers"] == {
            "a": "2 billion",
            "b": "200 billion",
            "c": "20 quadrillion",
        }
        assert q["question"] == "How many ants live on Earth?"
        assert q["alternative_answers"] == []

    def test_idempotent_already_mcq(self):
        q = self._q(type="text_multichoice", correct_answer="c",
                    possible_answers={"a": "x", "b": "y", "c": "z"})
        assert convert_question_inplace(q) is None
        # Re-running on the freshly-converted dict is also a no-op.
        q2 = self._q()
        convert_question_inplace(q2)
        assert convert_question_inplace(q2) is None

    def test_skip_when_possible_answers_already_present(self):
        q = self._q(possible_answers={"a": "x", "b": "y"})
        assert convert_question_inplace(q) is None

    def test_skip_when_no_options_pattern(self):
        q = self._q(question="What is the capital of France?")
        assert convert_question_inplace(q) is None

    def test_skip_when_answer_ambiguous(self):
        q = self._q(correct_answer="billion")  # matches two options
        assert convert_question_inplace(q) is None
        assert q["type"] == "text"  # untouched

    def test_skip_when_answer_unmatchable(self):
        q = self._q(correct_answer="zero")
        assert convert_question_inplace(q) is None

    def test_handles_substring_match_via_alt_answers(self):
        # "20 quadrillion ants" → alts include "20 quadrillion" → option 'c'.
        q = self._q(
            correct_answer="20 quadrillion ants",
            alternative_answers=["20 quadrillion", "quadrillions"],
        )
        rec = convert_question_inplace(q)
        assert rec is not None
        assert q["correct_answer"] == "c"


class TestProcessFile:
    def test_idempotent_double_run(self, tmp_path: Path):
        # Two real-shape questions in one file.
        payload = {
            "questions": [
                {
                    "id": "q1",
                    "question": "How many ants: 2 billion, 200 billion, or 20 quadrillion?",
                    "type": "text",
                    "correct_answer": "20 quadrillion",
                    "possible_answers": None,
                    "alternative_answers": [],
                    "topic": "Nature",
                    "category": "adults",
                    "difficulty": "medium",
                },
                {
                    "id": "q2",
                    "question": "Which is older: Egypt or Sudan?",
                    "type": "text",
                    "correct_answer": "Sudan",
                    "possible_answers": None,
                    "alternative_answers": [],
                    "topic": "History",
                    "category": "adults",
                    "difficulty": "medium",
                },
            ]
        }
        fp = tmp_path / "batch.json"
        fp.write_text(json.dumps(payload, indent=2))
        first = process_file(fp, dry_run=False)
        assert len(first) == 2
        after_first = fp.read_text()
        second = process_file(fp, dry_run=False)
        assert second == []
        assert fp.read_text() == after_first

    def test_dry_run_does_not_mutate(self, tmp_path: Path):
        payload = {
            "questions": [
                {
                    "id": "q1",
                    "question": "How many ants: 2 billion, 200 billion, or 20 quadrillion?",
                    "type": "text",
                    "correct_answer": "20 quadrillion",
                    "possible_answers": None,
                    "alternative_answers": [],
                    "topic": "Nature",
                    "category": "adults",
                    "difficulty": "medium",
                },
            ]
        }
        fp = tmp_path / "batch.json"
        fp.write_text(json.dumps(payload, indent=2))
        before = fp.read_text()
        changes = process_file(fp, dry_run=True)
        assert len(changes) == 1
        assert fp.read_text() == before


class TestConvertedQuestionRoundTripsThroughPydantic:
    """42.11 acceptance: converted question must validate via Pydantic with
    ``type=text_multichoice`` and the new ``Question.type`` Literal validator
    (added in task 42.8) — i.e. we cannot accidentally write an invalid type.
    """

    def test_roundtrip(self):
        q = {
            "id": "test-rt",
            "question": "How many ants live on Earth: 2 billion, 200 billion, or 20 quadrillion?",
            "type": "text",
            "correct_answer": "20 quadrillion",
            "possible_answers": None,
            "alternative_answers": [],
            "topic": "Nature",
            "category": "adults",
            "difficulty": "medium",
        }
        convert_question_inplace(q)
        # Question.from_dict tolerates missing optional fields.
        parsed = Question.from_dict(q)
        assert parsed.type == "text_multichoice"
        assert parsed.possible_answers == {
            "a": "2 billion",
            "b": "200 billion",
            "c": "20 quadrillion",
        }
        assert parsed.correct_answer == "c"
        assert parsed.question.endswith("?")
        assert ":" not in parsed.question  # options-tail successfully stripped
