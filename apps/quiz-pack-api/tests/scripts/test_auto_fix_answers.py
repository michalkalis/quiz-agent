"""Tests for `scripts/auto_fix_answers.py` (Issue #42 task 42.2).

Why these tests matter:
- The fixer mutates committed data on disk, so idempotency (re-runs are
  no-ops) is the load-bearing property — verified end-to-end via
  ``process_file`` against a tmp file.
- The split must never produce an empty head or tail; otherwise we would
  silently destroy answers when authors write things like ``"— foo"``.
"""

from __future__ import annotations

import json
from pathlib import Path

from scripts.auto_fix_answers import (
    fix_question_inplace,
    merge_explanation,
    process_file,
    split_answer,
)


class TestSplitAnswer:
    def test_em_dash(self):
        head, tail = split_answer("Czech — 'robota' means forced labour")
        assert head == "Czech"
        assert tail == "'robota' means forced labour."

    def test_en_dash(self):
        head, tail = split_answer("Foo – something else here")
        assert head == "Foo"
        assert tail == "Something else here."

    def test_because(self):
        head, tail = split_answer("Red because the dye was cheap")
        assert head == "Red"
        assert tail == "The dye was cheap."

    def test_comma_because(self):
        head, tail = split_answer("Red, because the dye was cheap")
        assert head == "Red"
        assert tail == "The dye was cheap."

    def test_namely(self):
        head, tail = split_answer("Three planets, namely Mercury, Venus, Earth")
        assert head == "Three planets"
        assert "Mercury" in tail

    def test_no_delimiter(self):
        assert split_answer("Just a short answer") is None

    def test_empty_head_returns_none(self):
        assert split_answer(" — orphan tail") is None

    def test_empty_tail_returns_none(self):
        assert split_answer("Foo — ") is None

    def test_preserves_terminal_punct(self):
        _, tail = split_answer("Foo — already ends with period.")
        assert tail.endswith(".")
        assert not tail.endswith("..")


class TestMergeExplanation:
    def test_none_existing(self):
        assert merge_explanation(None, "Hello.") == "Hello."

    def test_empty_existing(self):
        assert merge_explanation("", "Hello.") == "Hello."

    def test_appends_with_space(self):
        assert merge_explanation("Existing.", "More.") == "Existing. More."

    def test_no_double_space(self):
        assert merge_explanation("Existing. ", "More.") == "Existing. More."

    def test_idempotent_substring(self):
        merged = merge_explanation("Has the tail already.", "Has the tail already.")
        assert merged == "Has the tail already."


class TestFixQuestionInPlace:
    def test_em_dash_moves_tail_to_explanation(self):
        q = {
            "id": "q1",
            "correct_answer": "Selective Availability — switched off in May 2000",
            "explanation": None,
        }
        rec = fix_question_inplace(q)
        assert rec is not None
        assert q["correct_answer"] == "Selective Availability"
        assert q["explanation"] == "Switched off in May 2000."
        assert rec["before"].startswith("Selective Availability —")
        assert rec["after"] == "Selective Availability"

    def test_preserves_existing_explanation(self):
        q = {
            "id": "q2",
            "correct_answer": "Foo — extra context here",
            "explanation": "Pre-existing note.",
        }
        fix_question_inplace(q)
        assert q["explanation"].startswith("Pre-existing note.")
        assert "Extra context here." in q["explanation"]

    def test_no_change_when_clean(self):
        q = {"id": "q3", "correct_answer": "Paris", "explanation": None}
        assert fix_question_inplace(q) is None
        assert q["correct_answer"] == "Paris"

    def test_non_string_answer_skipped(self):
        # Multi-select answers are stored as lists; skip cleanly.
        q = {"id": "q4", "correct_answer": ["a", "b"], "explanation": None}
        assert fix_question_inplace(q) is None


class TestProcessFileIdempotent:
    def test_double_run_is_noop(self, tmp_path: Path):
        sample = {
            "questions": [
                {
                    "id": "q1",
                    "correct_answer": "Foo — bar baz quux",
                    "explanation": None,
                },
                {
                    "id": "q2",
                    "correct_answer": "Already clean",
                    "explanation": "Original.",
                },
                {
                    "id": "q3",
                    "correct_answer": "Bromelain — an enzyme that breaks gelatin",
                    "explanation": "Existing.",
                },
            ]
        }
        f = tmp_path / "sample.json"
        f.write_text(json.dumps(sample))

        first = process_file(f, dry_run=False)
        assert len(first) == 2
        contents_after_first = f.read_text()

        second = process_file(f, dry_run=False)
        assert second == []
        assert f.read_text() == contents_after_first

    def test_handles_top_level_list(self, tmp_path: Path):
        # Some data files store a bare list rather than {"questions": [...]}.
        f = tmp_path / "list.json"
        f.write_text(
            json.dumps(
                [{"id": "q1", "correct_answer": "Foo — bar", "explanation": None}]
            )
        )
        changes = process_file(f, dry_run=False)
        assert len(changes) == 1
        loaded = json.loads(f.read_text())
        assert loaded[0]["correct_answer"] == "Foo"

    def test_dry_run_does_not_write(self, tmp_path: Path):
        f = tmp_path / "sample.json"
        original = json.dumps(
            {
                "questions": [
                    {"id": "q1", "correct_answer": "Foo — bar", "explanation": None}
                ]
            }
        )
        f.write_text(original)
        changes = process_file(f, dry_run=True)
        assert len(changes) == 1
        assert f.read_text() == original
