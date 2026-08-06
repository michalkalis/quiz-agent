"""#133 V9: a null extracted answer must not reach the client or crash the parse.

The intent classifier can return an answer intent whose ``answer`` is missing or
explicitly ``null`` — it decided the utterance was an answer but extracted
nothing from it. Two defects followed, both on the *already charged* submission:

- The flow projected ``None`` into ``evaluation.user_answer``. iOS decodes
  ``Evaluation.userAnswer`` as a non-optional ``String``, so one null failed the
  decode of the WHOLE response: the player lost the verdict (and the freemium
  question that paid for it) instead of seeing "said nothing".
- The parser's contamination guards call ``len()`` on the extracted answer, and
  ``.get("answer", "")`` returns ``None`` for an explicit null — ``TypeError``,
  surfaced as a 500.

Backend is the right side to fix per the API contract: the wire contract is an
empty string, which iOS already renders as "said nothing" and the evaluator
already grades "skipped".
"""

from __future__ import annotations

import os
from unittest.mock import AsyncMock, MagicMock

import pytest

from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

pytestmark = pytest.mark.asyncio


def _question() -> Question:
    return Question(
        id="q_null",
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _session() -> QuizSession:
    return QuizSession(
        session_id="s_null",
        user_id="u_1",
        phase=SessionPhase.ASKING,
        current_question_id="q_null",
        asked_question_ids=["q_null"],
        max_questions=10,
    )


def _flow(intent_data):
    """Flow whose parser returns one answer intent carrying ``intent_data``.

    The evaluator is the REAL one: an empty answer short-circuits before any LLM
    call, so this also pins that the coerced value lands in the evaluator's
    empty-answer branch rather than being graded as a wrong answer.
    """
    from app.evaluation.evaluator import AnswerEvaluator
    from app.quiz.flow import QuizFlowService

    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": intent_data}]
    )

    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=_question())
    retriever.get_next_question = AsyncMock(return_value=None)

    usage_tracker = MagicMock()
    usage_tracker.check_limit = AsyncMock(return_value=(True, 5, None))
    usage_tracker.record_question = AsyncMock()

    return QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=AnswerEvaluator(),
        tts_service=None,
        usage_tracker=usage_tracker,
        translation_service=None,
    )


@pytest.mark.parametrize(
    "intent_data",
    [
        pytest.param({}, id="missing_answer_key"),
        pytest.param({"answer": None}, id="explicit_null_answer"),
    ],
)
async def test_an_answer_intent_with_no_answer_is_projected_as_empty_string(
    intent_data,
):
    """``user_answer`` must always be a string on the wire.

    ``None`` here is not a cosmetic difference: it is an undecodable response for
    the iOS client, which loses the verdict for a question it was charged for.
    """
    flow = _flow(intent_data)

    result = await flow.process_answer(session=_session(), answer_text="mmm")

    assert result.evaluation is not None
    assert result.evaluation["user_answer"] == ""
    # The real evaluator's empty-answer contract: not scored as a wrong answer.
    assert result.evaluation["result"] == "skipped"
    assert result.evaluation["points"] == 0.0


def _parser_replying(content: str):
    from app.input.parser import InputParser

    message = MagicMock()
    message.content = content
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]

    async def _create(**_kwargs):
        return response

    parser = InputParser()
    parser.client.chat.completions.create = _create
    return parser


@pytest.mark.parametrize(
    "classifier_json",
    [
        pytest.param(
            '{"intents": [{"intent_type": "answer", '
            '"extracted_data": {"answer": null}}]}',
            id="null_answer",
        ),
        pytest.param(
            '{"intents": [{"intent_type": "answer", "extracted_data": null}]}',
            id="null_extracted_data",
        ),
    ],
)
async def test_a_null_in_the_classifier_json_does_not_raise(classifier_json):
    """The length/similarity guards ran ``len(None)`` → TypeError → 500.

    Normalising to "" keeps the answer intent (an empty answer is a legitimate
    state the evaluator downgrades to "skipped") and hands downstream readers a
    string, never None.
    """
    parser = _parser_replying(classifier_json)

    intents = await parser.parse(
        user_input="I really am not sure about this one",
        current_question="What is the capital of France?",
        phase="asking",
    )

    assert intents[0]["intent_type"] == "answer"
    assert intents[0]["extracted_data"]["answer"] == ""
