"""Compose the text that question TTS actually reads aloud.

The displayed question (``session.current_question_text``) stays stem-only;
MCQ options are appended here, at synthesis time only. Every synthesis path
(serve route + prefetch) must build the spoken text through this helper so
the TTS cache key matches across them.
"""

from typing import Any, Dict, Optional


def spoken_question_text(
    question_text: str, possible_answers: Optional[Dict[str, Any]] = None
) -> str:
    """Stem plus read-aloud MCQ options ("A: … B: …"); stem alone otherwise."""
    if not possible_answers:
        return question_text
    options = ". ".join(
        f"{key}: {value}" for key, value in sorted(possible_answers.items())
    )
    return f"{question_text} {options}."
