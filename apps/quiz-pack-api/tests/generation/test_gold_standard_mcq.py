"""MCQ gold-standard examples (issue #42 task 42.10).

These tests pin two things the plan demands:

1. Every MCQ entry in `data/examples/gold_standard.json` round-trips through
   `Question.from_dict` as a valid `text_multichoice` Question with a populated
   `possible_answers` dict and a `correct_answer` that is one of the option
   keys. If a future edit to gold_standard.json breaks this contract (typo'd
   key, missing options, value-as-correct_answer), CI fails before the
   broken example reaches the prompt and teaches the LLM the wrong shape.

2. `load_gold_standard` renders MCQ entries with an inline `Options:` line so
   the LLM sees the exact option-dict shape, not just a free-text answer.
   Without this, MCQ examples would look identical to text examples in the
   prompt and the LLM would have no demonstration of how to fill
   `possible_answers`.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.generation.examples import load_gold_standard
from app.scoring.multi_model_scorer import _ANSWER_TAIL_MARKERS, _ANSWER_WORD_CAP
from quiz_shared.models.question import Question


_GOLD_PATH = (
    Path(__file__).resolve().parents[4]
    / "data"
    / "examples"
    / "gold_standard.json"
)


def _load_all_examples() -> list[dict]:
    with _GOLD_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


def _load_mcq_examples() -> list[dict]:
    return [e for e in _load_all_examples() if e.get("type") == "text_multichoice"]


def _load_text_examples() -> list[dict]:
    return [e for e in _load_all_examples() if e.get("type") != "text_multichoice"]


@pytest.mark.parametrize("ex", _load_text_examples())
def test_gold_standard_answer_within_word_cap(ex: dict) -> None:
    """46.A3 acceptance: no gold-standard answer teaches the long form.

    Verbose answers in the prompt's gold-standard examples teach the model
    that a descriptive sentence is an acceptable `correct_answer` (issue #42
    notes; issue-46 motivation §"Pipeline gaps"). After A3 every text answer
    must be a clean canonical head within the word cap with no explanation
    tail — the context lives in the new `explanation` field instead.
    """
    answer = ex["answer"]
    assert len(answer.split()) <= _ANSWER_WORD_CAP, (
        f"Gold-standard answer {answer!r} exceeds the {_ANSWER_WORD_CAP}-word "
        "cap — move the context into `explanation`."
    )
    lowered = answer.lower()
    tail = next((m for m in _ANSWER_TAIL_MARKERS if m in lowered), None)
    assert tail is None, (
        f"Gold-standard answer {answer!r} carries an explanation tail "
        f"({tail!r}) — move it into `explanation`."
    )


def test_gold_standard_contains_at_least_three_mcq_examples() -> None:
    """42.10 acceptance: 2–3 MCQ examples land in gold_standard.json."""
    assert len(_load_mcq_examples()) >= 3


@pytest.mark.parametrize("ex", _load_mcq_examples())
def test_mcq_example_validates_as_text_multichoice_question(ex: dict) -> None:
    """Each MCQ example must construct a valid `text_multichoice` Question.

    This is the 42.10 acceptance criterion: "prompt-emitted JSON for a sample
    MCQ pattern validates against the Question Pydantic model with
    type=text_multichoice and possible_answers populated."
    """
    options = ex["possible_answers"]
    assert isinstance(options, dict) and len(options) in {2, 4}, (
        "MCQ options must be 2 (true_false) or 4 (general); got "
        f"{len(options) if isinstance(options, dict) else type(options)}"
    )

    correct_key = str(ex["answer"]).strip().lower()
    assert correct_key in options, (
        f"correct_answer {correct_key!r} not in possible_answers keys "
        f"{sorted(options)}"
    )

    # Distractor-substring leak check (42.10 prompt rule).
    correct_value = options[correct_key].strip().lower()
    for k, v in options.items():
        if k == correct_key:
            continue
        assert correct_value not in v.strip().lower(), (
            f"Distractor {k!r}={v!r} contains the correct value "
            f"{correct_value!r} as a substring — would give the answer away."
        )

    q = Question.from_dict(
        {
            "id": f"gold_{ex['pattern']}",
            "question": ex["question"],
            "type": "text_multichoice",
            "possible_answers": options,
            "correct_answer": correct_key,
            "topic": ex.get("topic", "general"),
            "category": "general",
            "difficulty": ex.get("difficulty", "medium"),
        }
    )
    assert q.type == "text_multichoice"
    assert q.possible_answers == options
    assert q.correct_answer == correct_key


def test_load_gold_standard_renders_mcq_options_inline() -> None:
    """MCQ examples must show their option dict in the prompt text.

    Without this, the LLM sees an MCQ example formatted identically to a text
    example (no `Options:` line) and has no concrete demonstration of how to
    structure `possible_answers`.
    """
    # Sample the full library and look for at least one MCQ example;
    # `load_gold_standard` random-samples, so we re-roll if no MCQ is picked.
    # 20 attempts is overkill — with ≥3 MCQ in ~55 entries and n=5 picks,
    # the per-attempt probability of zero MCQ is < (50/55)^5 ≈ 0.62, so the
    # cumulative miss probability over 20 attempts is ~5e-5.
    for _ in range(20):
        rendered = load_gold_standard(n=5)
        if "Options:" in rendered:
            assert "A)" in rendered and "B)" in rendered
            return
    pytest.fail("load_gold_standard never emitted an MCQ example in 20 tries")
