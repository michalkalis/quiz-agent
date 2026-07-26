"""A driver must be able to answer an MCQ with the letter the app read aloud.

``tts.question_speech`` now speaks the options ("Možnosti. Áčko: Paris. Béčko:
London."), so the app actively tells a hands-free driver to answer with a
letter. Only iOS's streaming STT path understood one — it resolves the letter
on-device and submits the option *value*. Everything else (the batch Whisper
endpoint ``/voice/submit``, and the answer-confirmation sheet) sends the raw
transcript to the backend, where:

* "béčko" matched neither the key nor the value → scored **incorrect**, and
* a bare "A" was under the parser's 2-character floor → the question was
  silently **skipped**, i.e. the app punished the driver for doing exactly what
  it had just asked.

These tests pin both halves shut. The Python vocabulary
(``app.evaluation.spoken_options``) is the tested one; the Swift table in
``MCQTranscriptMatcher`` is its on-device twin and is covered by
``MCQTranscriptMatcherTests``.
"""

import os
from unittest.mock import AsyncMock, MagicMock

import pytest

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from app.evaluation.evaluator import AnswerEvaluator
from app.evaluation.spoken_options import resolve_spoken_option
from app.input.parser import InputParser
from app.quiz.flow import QuizFlowService
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

OPTIONS = {"a": "Paris", "b": "London", "c": "Berlin", "d": "Madrid"}


def _make_question(qid: str = "q_current") -> Question:
    """An MCQ whose correct answer is option **b** — the one under test."""
    return Question(
        id=qid,
        question="Which city hosts the Wimbledon championships?",
        type="text_multichoice",
        possible_answers=OPTIONS,
        correct_answer="b",
        topic="Geography",
        category="adults",
        difficulty="easy",
    )


class TestSpokenOptionResolution:
    """The vocabulary a driver actually speaks, resolved to one option key."""

    @pytest.mark.parametrize(
        "utterance",
        [
            "b",  # bare key
            "B",  # STT capitalises sentence-initial letters
            "B.",  # ...and punctuates them
            "béčko",  # Slovak letter-name — exactly what the TTS speaks
            "becko",  # ...as an STT without diacritics writes it
            "bé",  # spoken shorthand
            "two",  # English position
            "second",
            "dva",  # Slovak position
            "druhá",
            "2",  # Whisper writes spoken numerals as digits
            "možnosť béčko",  # the letter inside a short phrase
        ],
    )
    def test_every_spoken_form_of_option_b_resolves_to_b(self, utterance):
        assert resolve_spoken_option(utterance, OPTIONS) == "b"

    @pytest.mark.parametrize("utterance", ["", "Tokyo", "pričko", "neviem"])
    def test_unrecognized_utterance_resolves_to_nothing(self, utterance):
        """No match must stay no match — never a nearest-neighbour guess."""
        assert resolve_spoken_option(utterance, OPTIONS) is None

    @pytest.mark.parametrize("utterance", ["áčko alebo béčko", "one or four"])
    def test_two_candidates_resolve_to_nothing(self, utterance):
        """Ambiguity is not a scoring event.

        Same rule as the iOS matcher: an utterance naming two options is handed
        back unresolved so the normal evaluation path deals with it, because a
        guess here is scored against the driver.
        """
        assert resolve_spoken_option(utterance, OPTIONS) is None

    def test_position_beyond_the_option_count_resolves_to_nothing(self):
        """A true/false pair has no third option to select."""
        assert resolve_spoken_option("tri", {"a": "True", "b": "False"}) is None


class TestSpokenLetterScoresLikeTappingTheOption:
    """WHY: saying the letter must be worth what tapping the option is worth.

    Tapping option B submits its *value* ("London"). Every spoken form of B has
    to land on the same score, otherwise the hands-free driver is graded on a
    harder scale than the passenger with a thumb.
    """

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "utterance", ["b", "B", "béčko", "becko", "bé", "dva", "two", "second", "2"]
    )
    async def test_spoken_correct_option_scores_as_a_tap(self, utterance):
        question = _make_question()
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("MCQ answers must never reach the LLM path")
        )

        tapped = await evaluator.evaluate("London", question, question.question)
        spoken = await evaluator.evaluate(utterance, question, question.question)

        assert tapped == ("correct", 1.0)
        assert spoken == tapped

    @pytest.mark.asyncio
    @pytest.mark.parametrize("utterance", ["céčko", "tri", "third"])
    async def test_spoken_wrong_option_scores_as_tapping_that_wrong_option(
        self, utterance
    ):
        """Naming option C is worth what tapping C is worth: nothing.

        The symmetric half of the guarantee — understanding the letter must not
        become a free point, and must not fall through to the LLM path where an
        MCQ answer could earn partial credit the picker can't give.
        """
        question = _make_question()
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("MCQ answers must never reach the LLM path")
        )

        tapped = await evaluator.evaluate("Berlin", question, question.question)
        spoken = await evaluator.evaluate(utterance, question, question.question)

        assert tapped == ("incorrect", 0.0)
        assert spoken == tapped


class TestBareLetterIsAnsweredNotSkipped:
    """WHY: a one-letter answer must never be read as "no input".

    The parser's 2-character floor exists to stop the LLM hallucinating an
    intent out of silence. On a multiple-choice question that floor swallowed
    the one utterance the app had just prompted for, and a skip is
    unrecoverable — the question is scored 0 and gone.
    """

    def _make_flow(self, question: Question) -> QuizFlowService:
        parser = InputParser()
        # A spoken letter is the driving hot path; it must resolve locally.
        # Any LLM round-trip here is both a latency bug and a sign the
        # short-input guard swallowed the answer before the fast path ran.
        parser.client = MagicMock()
        parser.client.chat.completions.create = AsyncMock(
            side_effect=AssertionError("a spoken letter must not need an LLM call")
        )

        question_retriever = MagicMock()
        question_retriever.get = MagicMock(return_value=question)
        question_retriever.get_next_question = MagicMock(
            return_value=_make_question("q_next")
        )

        return QuizFlowService(
            session_manager=MagicMock(),
            input_parser=parser,
            question_retriever=question_retriever,
            answer_evaluator=AnswerEvaluator(),
            tts_service=None,
            usage_tracker=None,
            translation_service=None,
        )

    def _make_session(self) -> QuizSession:
        return QuizSession(
            session_id="s_1",
            user_id="u_1",
            language="sk",
            phase=SessionPhase.ASKING,
            current_question_id="q_current",
            asked_question_ids=["q_current"],
            max_questions=10,
        )

    @pytest.mark.asyncio
    @pytest.mark.parametrize("utterance", ["B", "b", "2"])
    async def test_single_character_mcq_answer_is_scored(self, utterance):
        session = self._make_session()
        flow = self._make_flow(_make_question())

        result = await flow.process_answer(session=session, answer_text=utterance)

        assert result.evaluation["result"] == "correct"
        assert result.evaluation["points"] == 1.0
        assert session.current_question_id == "q_next"

    @pytest.mark.asyncio
    async def test_single_character_answer_on_an_open_question_still_skips(self):
        """Control: the guard keeps protecting open questions.

        Without options to resolve against, a stray character is still the
        transcription noise the guard was written for — it must not become an
        LLM prompt.
        """
        open_question = Question(
            id="q_current",
            question="Who painted the Mona Lisa?",
            type="text",
            correct_answer="Leonardo da Vinci",
            topic="Art",
            category="adults",
            difficulty="easy",
        )
        session = self._make_session()
        flow = self._make_flow(open_question)

        result = await flow.process_answer(session=session, answer_text="a")

        assert result.evaluation["result"] == "skipped"
