"""PackLanguageChecker — the #211 naturalness check run over a customer pack.

Why: the pack check must reuse the corpus check (same editor prompt, model and
kinds) without changing what the corpus importer sends, and it must only ever
propose edits for parts a question actually has, so the caller never writes
an invented option or an answer onto a multiple-choice question.
"""

from __future__ import annotations

import json

from app.generation import naturalness_check
from app.generation.naturalness_check import NaturalnessChecker
from app.generation.pack_language_check import _PACK_NOTE, build_prompt, parse
from quiz_shared.models.question import Question


def _q(text: str, **kw) -> Question:
    return Question(
        id="q_1",
        question=text,
        correct_answer=kw.pop("correct_answer", "Hedwiga"),
        topic="t",
        category="general",
        difficulty="easy",
        language="sk",
        **kw,
    )


def test_corpus_prompt_is_unchanged_by_the_pack_check() -> None:
    prompt = NaturalnessChecker._build_prompt([_q("Otázka?")])
    assert prompt == naturalness_check._PROMPT_HEADER + "\n1. [sk] Otázka?"
    assert _PACK_NOTE not in prompt


def test_pack_prompt_keeps_the_corpus_editor_and_adds_context_and_answers() -> None:
    new = _q("Ako sa volá sova?", explanation="Biela sova.")
    saved = _q("Kto poslal sovu Hedvigu?", correct_answer="Hagrid")

    prompt = build_prompt([new], [saved])

    assert prompt.startswith(naturalness_check._PROMPT_HEADER + _PACK_NOTE)
    assert "- Kto poslal sovu Hedvigu? | Answer: Hagrid" in prompt
    assert prompt.endswith(
        "1. [sk] Ako sa volá sova?\n   Answer: Hedwiga\n   Explanation: Biela sova."
    )


def test_parse_keeps_only_edits_for_parts_the_question_has() -> None:
    mcq = _q("Ktorá sova?", possible_answers={"a": "Hedwiga", "b": "Errol"})
    reply = json.dumps(
        {
            "checks": [
                {
                    "index": 1,
                    "ok": False,
                    "problems": [{"kind": "name", "quote": "Hedwiga"}],
                    "rewrite": "Ktorá sova?",
                    "fields": {
                        "answer": "Hedviga",
                        "options": {"a": "Hedviga", "x": "new"},
                        "explanation": "none to fix",
                    },
                },
                {
                    "index": 2,
                    "ok": False,
                    "problems": [],
                    "rewrite": "x",
                },  # flagged, no problem
                {
                    "index": 3,
                    "ok": False,
                    "problems": [{"kind": "made_up", "quote": "x"}],
                    "rewrite": "x",
                },  # unknown kind only
            ]
        }
    )

    first, second, third = parse(reply, [mcq, _q("b"), _q("c")])

    assert first.edits == {"question": "Ktorá sova?", "option:a": "Hedviga"}
    assert second is None and third is None
