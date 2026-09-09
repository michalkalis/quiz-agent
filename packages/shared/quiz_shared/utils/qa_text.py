"""The question+answer text behind ``embedding_qa`` (#170 D2).

One definition, shared by every writer and reader of the column — the
backfill script, the corpus importer and the dedup query — so a candidate is
always compared against the corpus with byte-identical input formatting.
A second copy anywhere would silently split the vector space in two.
"""

from __future__ import annotations

from typing import Any, Dict, Optional


def qa_text(
    question: str, correct_answer: Any, possible_answers: Optional[Dict[str, str]]
) -> str:
    """The text that gets embedded: question + the answer as the player hears it.

    MCQ rows store the option TEXT in ``correct_answer`` since the 2026-07-11
    pilot fix; a bare option letter (legacy rows) is resolved through
    ``possible_answers`` so two rows with the same fact embed the same way.
    """
    answer = correct_answer
    if isinstance(possible_answers, dict) and isinstance(answer, str):
        answer = possible_answers.get(answer, answer)
    return f"Question: {question}\nAnswer: {answer}"
