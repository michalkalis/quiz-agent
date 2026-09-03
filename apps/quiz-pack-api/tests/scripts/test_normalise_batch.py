"""Tests for `scripts/normalise_batch.py` (founder blind rating 2026-09-03).

Why these matter: the CLI is how batches generated BEFORE the pipeline fix get
repaired — an offline re-run over a `--out` dump that has already been rated.
It must write back the same shape `Question.from_dict` reads (a converted
question is only useful if the importer can still load it) and must leave
every question the normaliser declines to touch byte-identical, so a re-run
over an already-normalised file is a no-op.
"""

from __future__ import annotations

import json

from quiz_shared.models.question import Question

import scripts.normalise_batch as normalise_batch


def _dump(**overrides) -> dict:
    base = Question(
        id="00000000-0000-0000-0000-000000000001",
        question="How many bones are inside an elephant's trunk: closer to "
        "zero, 40, or 400?",
        correct_answer="Zero",
        topic="Animals",
        category="general",
        difficulty="medium",
    ).model_dump(mode="json")
    base.update(overrides)
    return base


def test_converts_and_stays_loadable_as_a_question() -> None:
    questions = [_dump()]

    counts, changes = normalise_batch.normalise_batch(questions)

    # A conversion always rewrites its stem; `stem_options_stripped` counts
    # only MCQs that already had options and merely recited them, so the two
    # numbers never double-count the same question (PR #76 review, finding 10).
    assert counts.inline_options_to_mcq == 1
    assert counts.stem_options_stripped == 0
    assert changes[0]["before"] != changes[0]["after"]
    restored = Question.from_dict(questions[0])
    assert restored.type == "text_multichoice"
    assert restored.question == "How many bones are inside an elephant's trunk?"
    assert restored.possible_answers == {"a": "Zero", "b": "40", "c": "400"}
    assert restored.correct_answer == "Zero"


def test_second_run_changes_nothing() -> None:
    questions = [_dump()]
    normalise_batch.normalise_batch(questions)
    snapshot = json.dumps(questions, sort_keys=True)

    counts, changes = normalise_batch.normalise_batch(questions)

    assert (counts.inline_options_to_mcq, counts.stem_options_stripped) == (0, 0)
    assert changes == []
    assert json.dumps(questions, sort_keys=True) == snapshot


def test_leaves_a_plain_free_text_question_untouched() -> None:
    questions = [
        _dump(
            question="Cabin windows are oval or rounded, never square. Why?",
            correct_answer="Sharp corners concentrate stress",
        )
    ]
    snapshot = json.dumps(questions, sort_keys=True)

    counts, changes = normalise_batch.normalise_batch(questions)

    assert counts.as_info() == {
        "inline_options_to_mcq": 0,
        "stem_options_stripped": 0,
        "inline_options_unmatched": 0,
    }
    assert changes == []
    assert json.dumps(questions, sort_keys=True) == snapshot
