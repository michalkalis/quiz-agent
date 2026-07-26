"""Build the exact text handed to TTS for a quiz question.

A driver never sees the option picker, so a multiple-choice question is
unanswerable hands-free unless the choices are spoken. The read-out is built
here, at synthesis time only — the displayed question text is untouched, the
same display-vs-speech split ``normalize_numbers_for_tts`` already established
(founder bug 2026-07-12).

Every site that synthesizes question audio (the /question/audio route and the
prefetch warm-up) MUST build its text through this one function: the TTS cache
key is a hash of the final string, so any divergence makes the warm-up write a
key nobody ever reads — a silent double-spend that also costs the driver the
full synthesis latency on the hot path.
"""

from quiz_shared.models.question import Question

from ..translation.feedback_messages import get_option_letter, get_options_label
from .number_normalization import normalize_numbers_for_tts


def build_question_speech_text(
    question_text: str, question: Question | None, language: str
) -> str:
    """Return the TTS input for ``question_text`` in ``language``.

    ``question`` supplies the multiple-choice options; pass None when the
    question row is unavailable, which simply omits the read-out. Only
    ``text_multichoice`` questions with options get one — true/false questions
    already name both choices in their wording, open questions have none.
    """
    spoken = question_text

    if (
        question is not None
        and question.type == "text_multichoice"
        and question.possible_answers
    ):
        options = " ".join(
            f"{get_option_letter(key, language)}: {value}."
            for key, value in sorted(question.possible_answers.items())
        )
        spoken = f"{question_text} {get_options_label(language)}. {options}"

    # Options join BEFORE normalization: option values are frequently bare
    # numbers ("10", "100", "240"), the exact digits-read-in-English defect.
    return normalize_numbers_for_tts(spoken, language)
