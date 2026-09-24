"""Compose the text that question TTS actually reads aloud.

The displayed question (``session.current_question_text``) stays stem-only;
MCQ options are appended here, at synthesis time only. Every synthesis path
(serve route + prefetch) must build the spoken text through this helper so
the TTS cache key matches across them.
"""

from typing import Any, Dict, Optional

from ..client_capabilities import OPTION_LABELS, has_capability
from ..evaluation.mcq_matcher import option_labels


def spoken_question_text(
    question_text: str,
    possible_answers: Optional[Dict[str, Any]] = None,
    session: Any = None,
) -> str:
    """Stem plus read-aloud MCQ options ("a: … b: …"); stem alone otherwise.

    #185 G: a session that declared ``option-labels`` hears the served labels
    ("1: … 2: …", or "A: … B: …" when the options are numbers) — the ones its
    client displays. Every other session hears the keys exactly as before, so
    its text (and TTS cache key) is unchanged.
    """
    if not possible_answers:
        return question_text
    labels: Dict[str, str] = {key: key for key in possible_answers}
    if has_capability(session, OPTION_LABELS):
        labels = option_labels(possible_answers)
    options = ". ".join(
        f"{labels[key]}: {value}" for key, value in sorted(possible_answers.items())
    )
    return f"{question_text} {options}."
