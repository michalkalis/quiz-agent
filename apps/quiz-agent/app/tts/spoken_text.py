"""Compose the text that question TTS actually reads aloud.

The displayed question (``session.current_question_text``) stays stem-only;
MCQ options are appended here, at synthesis time only. Every synthesis path
(serve route + prefetch) must build the spoken text through this helper so
the TTS cache key matches across them.
"""

from typing import Any, Dict, Optional

from ..client_capabilities import OPTION_LABELS, has_capability
from ..evaluation.mcq_matcher import option_labels, spoken_label


def spoken_question_text(
    question_text: str,
    possible_answers: Optional[Dict[str, Any]] = None,
    session: Any = None,
) -> str:
    """Stem plus read-aloud MCQ options ("a: … b: …"); stem alone otherwise.

    #185 G: a session that declared ``option-labels`` hears the served labels
    its client displays, numbers in the counting form of the session language
    (sk "Jedna: … Dva: …", cs "… Tři: … Čtyři: …", en "One: … Two: …") and
    letters as letters ("A: … B: …" when the options are numbers). Every other
    session hears the keys exactly as before, so its text (and TTS cache key)
    is unchanged.
    """
    if not possible_answers:
        return question_text
    labels: Dict[str, str] = {key: key for key in possible_answers}
    if has_capability(session, OPTION_LABELS):
        language = getattr(session, "language", None)
        labels = {
            key: spoken_label(label, language)
            for key, label in option_labels(possible_answers).items()
        }
    options = ". ".join(
        f"{labels[key]}: {value}" for key, value in sorted(possible_answers.items())
    )
    return f"{question_text} {options}."
