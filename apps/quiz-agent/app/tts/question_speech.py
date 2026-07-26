"""Build the exact text handed to TTS for a quiz question.

A driver never sees the option picker, so a multiple-choice question is
unanswerable hands-free unless the choices are spoken. The read-out is built
here, at synthesis time only — the displayed question text is untouched, the
same display-vs-speech split ``normalize_numbers_for_tts`` already established
(founder bug 2026-07-12).

Call this where the question is chosen (routes.quiz.start_quiz,
QuizFlowService.process_answer) and store the result in
``session.current_question_speech_text``: the TTS warm-up and /question/audio
then synthesize one and the same string. The cache key is a hash of that final
string, so any divergence makes the warm-up write a key nobody ever reads — a
silent double-spend that also costs the driver the full synthesis latency on
the hot path.
"""

from quiz_shared.models.question import Question

from ..translation.feedback_messages import get_option_letter, get_options_label
from .number_normalization import normalize_numbers_for_tts

# A true/false question is NOT stored as a plain text row: the generation
# pipeline routes the `true_false` pattern through PATTERNS_TO_MCQ and emits
# `type=text_multichoice` with `{"a": "True", "b": "False"}` (see
# apps/quiz-pack-api/app/generation/{pattern_routing,advanced_generator}.py),
# so the type alone does not tell the two shapes apart.
_TRUE_FALSE_OPTION_VALUES = frozenset({"true", "false"})
_TRUE_FALSE_PATTERN = "true_false"


def _is_true_false(question: Question) -> bool:
    """Whether ``question``'s options are a true/false pair.

    Two signals, because each alone has a hole. The option values are what the
    whole corpus carries today (same normalized comparison as
    ``craft_guards.true_false_key``, the recognizer the generation pipeline
    scores T/F balance with). The generator's ``reasoning_pattern`` provenance
    is the one that survives option values being translated some day — the
    question text is translated today, the options are not.
    """
    provenance = question.generation_metadata
    if provenance is not None and provenance.reasoning_pattern == _TRUE_FALSE_PATTERN:
        return True

    values = {
        str(v).strip().lower() for v in (question.possible_answers or {}).values()
    }
    return values == _TRUE_FALSE_OPTION_VALUES


def build_question_speech_text(
    question_text: str, question: Question | None, language: str
) -> str:
    """Return the TTS input for ``question_text`` in ``language``.

    ``question`` supplies the multiple-choice options; pass None when the
    question row is unavailable, which simply omits the read-out. Only
    ``text_multichoice`` questions with options get one — open questions have
    none, and a true/false question already names both choices in its own
    wording, so reading "Áčko: True. Béčko: False." after "Pravda alebo
    nepravda: …" is pure noise in a language the option values aren't even in.
    """
    spoken = question_text

    if (
        question is not None
        and question.type == "text_multichoice"
        and question.possible_answers
        and not _is_true_false(question)
    ):
        options = " ".join(
            f"{get_option_letter(key, language)}: {value}."
            for key, value in sorted(question.possible_answers.items())
        )
        spoken = f"{question_text} {get_options_label(language)}. {options}"

    # Options join BEFORE normalization: option values are frequently bare
    # numbers ("10", "100", "240"), the exact digits-read-in-English defect.
    return normalize_numbers_for_tts(spoken, language)
