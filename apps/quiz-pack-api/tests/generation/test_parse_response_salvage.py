"""Per-question salvage in `AdvancedQuestionGenerator._parse_response` (#167).

Why these scenarios:

The #167 entertainment pilot died at generation twice in a row: the single
batched generation call returned JSON that failed one whole-batch `json.loads`
(`Expecting ',' delimiter` deep inside — the signature of an unescaped `"` in a
string, which pop-culture titles produce constantly), and because the parse was
one `json.loads` over the entire batch with no salvage, all ~29 questions were
lost and the F8 guard then killed the batch. These tests pin the fix:

- `test_valid_batch_parses_without_touching_salvage` is the regression brake on
  the *happy path*. Salvage is only ever allowed to run on the failure branch
  (which returned `[]` before), so a well-formed batch must reach the same
  questions through the same single `json.loads` it always did. The test makes
  the salvage entry point explode if it is ever reached.
- `test_one_broken_object_does_not_sink_the_batch` is the #167 failure mode
  itself: one corrupt question object must cost exactly one question, not the
  whole batch, and the loss must be *loud* (a warning naming how many were
  salvaged and how many were lost) — a silent partial batch would be worse than
  the crash it replaces.
- `test_unescaped_inner_quote_is_repaired` pins the bounded repair: the exact
  corruption #167 hit (an unescaped quote inside a title) is deterministically
  fixable, so that question should come back *whole*, with the quoted title's
  characters preserved.
- `test_garbled_payload_returns_empty_without_raising` pins the floor: when
  nothing is recoverable, behaviour falls back to today's — empty list, no
  exception escaping into the generation pipeline.
"""

from __future__ import annotations

import logging

import pytest

from app.generation.advanced_generator import AdvancedQuestionGenerator


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """Avoid ChatOpenAI's env-var assertion at construction time."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


def _generator() -> AdvancedQuestionGenerator:
    return AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )


def _question_object(qid: str, question: str, difficulty: str = '"medium"') -> str:
    """One question object in the shape the real generation reply emits.

    `question` and `difficulty` are spliced in raw so a test can inject the
    exact malformation it is pinning.
    """
    return f"""    {{
      "id": "{qid}",
      "reasoning": {{"pattern_used": "open_question", "why_interesting": "x",
        "universal_appeal": "x", "boring_check": "x"}},
      "question": "{question}",
      "type": "text",
      "correct_answer": "The Matrix",
      "possible_answers": null,
      "alternative_answers": [],
      "topic": "Film",
      "difficulty": {difficulty},
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    }}"""


def _batch(*objects: str) -> str:
    """Wrap question objects in the `{"questions": [...]}` reply envelope."""
    joined = ",\n".join(objects)
    return '{\n  "questions": [\n' + joined + "\n  ]\n}"


_VALID_BATCH = _batch(
    _question_object("q1", "Which 1999 film popularised 'bullet time'?"),
    _question_object("q2", "Which band released 'A Night at the Opera'?"),
)


def test_valid_batch_parses_without_touching_salvage(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A well-formed batch must take the untouched single-`json.loads` path.

    Salvage is purely additive only as long as it stays on the failure branch;
    if it ever ran on good input it could quietly change which questions come
    back. Blowing up the salvage entry point makes that regression impossible
    to miss.
    """

    def _explode(*_args, **_kwargs):  # pragma: no cover — must never run
        raise AssertionError("salvage ran on a well-formed batch")

    monkeypatch.setattr(
        AdvancedQuestionGenerator, "_salvage_question_objects", _explode
    )

    questions = _generator()._parse_response(
        _VALID_BATCH, default_category="entertainment"
    )

    assert [q.question for q in questions] == [
        "Which 1999 film popularised 'bullet time'?",
        "Which band released 'A Night at the Opera'?",
    ]
    assert all(q.category == "entertainment" for q in questions)


def test_one_broken_object_does_not_sink_the_batch(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """#167: one unparseable question object costs one question, not ~29.

    The middle object carries a bare (unquoted) `medium` token — malformed in a
    way inner-quote repair deliberately cannot fix — so it is genuinely lost.
    The other two must still arrive, and the loss must be reported loudly with
    the salvaged/lost counts.
    """
    batch = _batch(
        _question_object("q1", "First question?"),
        _question_object("q2", "Broken question?", difficulty="medium"),
        _question_object("q3", "Third question?"),
    )

    with caplog.at_level(logging.WARNING, logger="app.generation.advanced_generator"):
        questions = _generator()._parse_response(batch)

    assert [q.question for q in questions] == ["First question?", "Third question?"]
    log = caplog.text
    assert "salvaged 2 of 3 question objects, 1 lost" in log
    assert "dropped 1 unparseable question object" in log


def test_unescaped_inner_quote_is_repaired() -> None:
    """The exact #167 corruption: a title quoted inside the question string.

    `Who directed "Dune"?` reaches us with the inner quotes unescaped, which is
    what broke the whole-batch parse. The repair is deterministic here, so the
    question should survive intact — characters preserved, nothing lost.
    """
    batch = _batch(
        _question_object("q1", "First question?"),
        _question_object("q2", 'Who directed "Dune" in 2021?'),
    )

    questions = _generator()._parse_response(batch)

    assert [q.question for q in questions] == [
        "First question?",
        'Who directed "Dune" in 2021?',
    ]


def test_garbled_payload_returns_empty_without_raising() -> None:
    """Unrecoverable input falls back to today's behaviour: `[]`, no raise.

    Salvage must never turn a parse failure into an exception escaping into the
    generation pipeline — the caller's contract is still "a list of questions".
    """
    assert _generator()._parse_response("{ not json at all: %%% <<< }") == []
