"""MCQ answer resolution shared by GenerationStage and the generator itself.

Lives outside the orchestrator so `AdvancedQuestionGenerator._finalize_questions`
can normalize at the parse boundary: eval scripts call `_generate_batch`
directly and bypass `GenerationStage`, which is how D21b q45 shipped a
bare-letter answer ("c") in 2026-08.
"""

from __future__ import annotations


def resolve_mcq_answer(
    possible_answers: dict | None, correct_answer: object
) -> str | None:
    """Full option text for a well-formed MCQ, else None (= drop).

    Well-formed: ≥2 options, every option text non-blank, and
    `correct_answer` resolves to an option — either as its key letter
    ("c", the prompt contract) or as its full text. Pilot 2026-07-11
    shipped bare-letter answers and blank-text options to founder review
    across all three candidate models; storing the resolved text keeps
    `correct_answer` self-contained for the TTS reveal, review renders
    and the evaluator regardless of which form the model emitted.
    """
    if isinstance(correct_answer, list):
        correct_answer = correct_answer[0] if correct_answer else None
    if not possible_answers or len(possible_answers) < 2 or not correct_answer:
        return None
    if any(not str(v).strip() for v in possible_answers.values()):
        return None
    wanted = str(correct_answer).strip().lower()
    for key, value in possible_answers.items():
        if str(key).strip().lower() == wanted:
            return str(value)
    for value in possible_answers.values():
        if str(value).strip().lower() == wanted:
            return str(value)
    return None
