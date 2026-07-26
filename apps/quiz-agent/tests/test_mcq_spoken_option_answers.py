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

from tests.question_audio_harness import StubTranslator, start_quiz_for

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

    @pytest.mark.parametrize(
        "utterance", ["one hundred", "two hundred and forty", "sto"]
    )
    def test_a_spoken_numeric_value_is_not_read_as_a_position(self, utterance):
        """Speaking a numeric option out loud must not select a different one.

        Bare numerals are this corpus's most common option shape, so "one
        hundred" against {a: 10, b: 100} used to resolve on its leading "one"
        and hand back option A — scoring the driver's correct answer as wrong
        (and, where A happened to be correct, a wrong answer as right). Position
        words only count when they are the entire utterance; matching a spoken
        VALUE is the evaluator's job, not this resolver's.
        """
        numeric = {"a": "10", "b": "100", "c": "240"}
        assert resolve_spoken_option(utterance, numeric) is None

    def test_a_leading_slovak_conjunction_is_not_read_as_option_a(self):
        """The Slovak word for "and" is "a" — it must not select option A.

        The read-out prompts drivers to speak letters, so a bare letter sitting
        inside ordinary speech would otherwise be picked up and scored.
        """
        assert resolve_spoken_option("a to je Londýn", OPTIONS) is None


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
        # Scoring alone cannot tell "resolved to C" from "understood nothing" —
        # both are worth 0.0. Pin the resolution so this test fails if the
        # letter stops being understood.
        assert resolve_spoken_option(utterance, OPTIONS) == "c"


class TestTranslatedOptionValueScoresLikeTheEnglishOne:
    """WHY: the driver answers with the option they were GIVEN, not the row's.

    Picking an option submits its value — iOS ``submitMCQAnswer`` posts
    ``value``, never the key, whether it came from a tap or from the streaming
    matcher. Now that a Slovak session is shown and read "Áčko: Paríž", that
    value is the Slovak one, while the question row stays English-only. If
    evaluation only knew the row, translating the options would silently score
    every picked answer in every non-English session incorrect.
    """

    @pytest.mark.asyncio
    async def test_translated_value_scores_like_the_english_value(self):
        question = _make_question()
        shown = {"a": "Paríž", "b": "Londýn", "c": "Berlín", "d": "Madrid"}
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("MCQ answers must never reach the LLM path")
        )

        english = await evaluator.evaluate("London", question, question.question)
        translated = await evaluator.evaluate(
            "Londýn", question, question.question, shown_options=shown
        )

        assert english == ("correct", 1.0)
        assert translated == english

    @pytest.mark.asyncio
    async def test_translated_wrong_value_is_still_wrong(self):
        """The map resolves which option was named — it never grants the point."""
        question = _make_question()
        shown = {"a": "Paríž", "b": "Londýn", "c": "Berlín", "d": "Madrid"}
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("MCQ answers must never reach the LLM path")
        )

        assert await evaluator.evaluate(
            "Berlín", question, question.question, shown_options=shown
        ) == ("incorrect", 0.0)

    @pytest.fixture
    def _no_rate_limit(self, monkeypatch):
        from app import rate_limit

        monkeypatch.setattr(rate_limit.limiter, "enabled", False)

    @pytest.mark.asyncio
    async def test_start_hands_the_flow_the_options_it_showed(self, _no_rate_limit):
        """The wiring, end to end: what /start showed is what /input scores.

        Driving the real /start rather than hand-setting the session field is
        the point — the two must be the same map, and only the route that
        translated the options can prove it.
        """
        question = _make_question()
        translator = StubTranslator(
            {
                "Which city hosts the Wimbledon championships?": (
                    "Ktoré mesto hostí Wimbledon?"
                ),
                "Paris": "Paríž",
                "London": "Londýn",
                "Berlin": "Berlín",
                # "Madrid" reads the same in Slovak — the passthrough case.
            }
        )

        manager, session_id, retriever = await start_quiz_for(
            question, "sk", translation_service=translator
        )
        session = manager.get_session(session_id)

        assert session.current_question_options == {
            "a": "Paríž",
            "b": "Londýn",
            "c": "Berlín",
            "d": "Madrid",
        }

        parser = MagicMock()
        parser.parse = AsyncMock(
            return_value=[
                {"intent_type": "answer", "extracted_data": {"answer": "Londýn"}}
            ]
        )
        flow = QuizFlowService(
            session_manager=manager,
            input_parser=parser,
            question_retriever=retriever,
            answer_evaluator=AnswerEvaluator(),
            tts_service=None,
            usage_tracker=None,
            translation_service=None,
        )

        result = await flow.process_answer(session=session, answer_text="Londýn")

        assert result.evaluation["result"] == "correct"
        assert result.evaluation["points"] == 1.0


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
