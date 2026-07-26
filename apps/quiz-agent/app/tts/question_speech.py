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

from collections.abc import Mapping

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
    is the one that survives translation: what the driver sees and hears is
    now translated per session, so only the untranslated row is asked here.
    """
    provenance = question.generation_metadata
    if provenance is not None and provenance.reasoning_pattern == _TRUE_FALSE_PATTERN:
        return True

    values = {
        str(v).strip().lower() for v in (question.possible_answers or {}).values()
    }
    return values == _TRUE_FALSE_OPTION_VALUES


def build_question_speech_text(
    question_text: str,
    question: Question | None,
    language: str,
    *,
    options: Mapping[str, str] | None,
) -> str:
    """Return the TTS input for ``question_text`` in ``language``.

    ``options`` are the option values as the client is shown them — the
    translated ones from ``serializers.question_to_dict_translated``, so the
    driver hears the same choices the screen lists. Pass None when there are
    none to read (an open question, or a lost question row).

    ``question`` is the untranslated row, and supplies only the shape signals
    that must stay language-independent: the type, and the true/false check
    (which reads the row's own English values on purpose — the values in
    ``options`` may be Slovak by then).

    Only ``text_multichoice`` questions with options get a read-out — open
    questions have none, and a true/false question already names both choices
    in its own wording, so reading "Áčko: Pravda. Béčko: Nepravda." after
    "Pravda alebo nepravda: …" is pure noise.
    """
    spoken = question_text

    if (
        question is not None
        and question.type == "text_multichoice"
        and options
        and not _is_true_false(question)
    ):
        spoken_options = " ".join(
            f"{get_option_letter(key, language)}: {value}."
            for key, value in sorted(options.items())
        )
        spoken = f"{question_text} {get_options_label(language)}. {spoken_options}"

    # Options join BEFORE normalization: option values are frequently bare
    # numbers ("10", "100", "240"), the exact digits-read-in-English defect.
    return normalize_numbers_for_tts(spoken, language)
