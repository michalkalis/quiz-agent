"""Whole-payload translation for non-English sessions (#132 track D, #126).

Founder TestFlight report 2026-07-29: in a Slovak session the stem arrived in
Slovak while the MCQ options and the result explanation stayed English. The same
split is the root cause of #126 — a Slovak spoken answer was matched against
English option text, so "Pravda"/"Nepravda" could never match deterministically
and every True/False answer fell through to the LLM (or scored wrong).

These tests encode the three things that must hold together, not separately:
  1. What the player is SHOWN (stem + options + explanation) is one language.
  2. What their answer is MATCHED against is the same translated text.
  3. What the result screen SAYS quotes those same strings.
Plus the two budget/safety invariants: exactly ONE LLM call per question payload,
and a failed translation degrades to English (loudly) instead of breaking a quiz.
"""

import asyncio
import json
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.serializers import (  # noqa: E402
    session_translation,
    translated_question_payload,
    translated_question_view,
)
from app.translation.translator import TranslationService  # noqa: E402
from quiz_shared.models.phase import SessionPhase  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.models.session import QuizSession  # noqa: E402


# ── Fixtures ─────────────────────────────────────────────────────────────────


MCQ_OPTIONS = {"a": "Paris", "b": "London", "c": "Berlin"}
MCQ_OPTIONS_SK = {"a": "Paríž", "b": "Londýn", "c": "Berlín"}
EXPLANATION = "Paris has been the capital of France since the 10th century."
EXPLANATION_SK = "Paríž je hlavným mestom Francúzska od 10. storočia."
STEM = "What is the capital city of France?"
STEM_SK = "Aké je hlavné mesto Francúzska?"


def mcq_question(qid: str = "q_mcq", correct: str = "Paris") -> Question:
    return Question(
        id=qid,
        question=STEM,
        type="text_multichoice",
        possible_answers=dict(MCQ_OPTIONS),
        correct_answer=correct,
        explanation=EXPLANATION,
        topic="Geography",
        category="general",
        difficulty="easy",
    )


def tf_question(qid: str = "q_tf") -> Question:
    return Question(
        id=qid,
        question="The Eiffel Tower is taller than the Statue of Liberty.",
        type="text_multichoice",
        possible_answers={"a": "True", "b": "False"},
        correct_answer="True",
        explanation="The Eiffel Tower is 330 m tall, the Statue of Liberty 93 m.",
        topic="Geography",
        category="general",
        difficulty="easy",
    )


def fake_translation_service(payload_return) -> MagicMock:
    """A translation service whose ONE payload call is fully under test control."""
    service = MagicMock()
    service.translate_question_payload = AsyncMock(return_value=payload_return)
    service.translate_feedback = AsyncMock(
        side_effect=AssertionError(
            "translate_feedback must not be called when a payload record exists — "
            "that would be a second LLM call per question"
        )
    )
    return service


SK_MCQ_PAYLOAD = {
    "question": STEM_SK,
    "options": dict(MCQ_OPTIONS_SK),
    "explanation": EXPLANATION_SK,
}

SK_TF_PAYLOAD = {
    "question": "Eiffelova veža je vyššia ako Socha slobody.",
    "options": {"a": "Pravda", "b": "Nepravda"},
    "explanation": "Eiffelova veža má 330 m, Socha slobody 93 m.",
}


def sk_session(question_id: str = "q_mcq") -> QuizSession:
    return QuizSession(
        session_id="s_sk",
        user_id="u_1",
        language="sk",
        phase=SessionPhase.ASKING,
        current_question_id=question_id,
        asked_question_ids=[question_id],
        max_questions=10,
    )


# ── 1. What the player is shown ──────────────────────────────────────────────


def test_served_payload_translates_stem_options_and_explanation_in_one_call():
    """The exact founder bug: options and explanation must not stay English while
    the stem is Slovak. One call carries all three — a per-field call would both
    multiply cost and let the stem and its options drift apart."""
    service = fake_translation_service(SK_MCQ_PAYLOAD)

    payload, record = asyncio.run(
        translated_question_payload(mcq_question(), "sk", service, session_id="s_sk")
    )

    assert payload["question"] == STEM_SK
    assert payload["possible_answers"] == MCQ_OPTIONS_SK
    assert payload["explanation"] == EXPLANATION_SK
    # Exactly one LLM round-trip for the whole payload.
    service.translate_question_payload.assert_awaited_once()
    sent = service.translate_question_payload.await_args[0][0]
    assert set(sent) == {"question", "options", "explanation"}
    # Structure/keys unchanged — only the language of the values moved (OpenAPI).
    assert set(payload["possible_answers"]) == set(MCQ_OPTIONS)
    assert record["correct_answer_key"] == "a"
    assert record["correct_answer"] == "Paríž"


def test_english_session_takes_the_untranslated_fast_path():
    """English is the corpus language: zero LLM calls, byte-identical payload.
    A regression here would silently double the cost of every English session."""
    service = fake_translation_service(SK_MCQ_PAYLOAD)

    payload, record = asyncio.run(
        translated_question_payload(mcq_question(), "en", service)
    )

    service.translate_question_payload.assert_not_awaited()
    assert record is None
    assert payload["question"] == STEM
    assert payload["possible_answers"] == MCQ_OPTIONS
    assert payload["explanation"] == EXPLANATION


def test_stored_record_is_reserved_without_retranslating():
    """/question and /question/audio re-read the record instead of paying for a
    second translation — and a stale record (other question, or the session's
    language changed) must never be applied to the wrong question."""
    session = sk_session()
    _, record = asyncio.run(
        translated_question_payload(
            mcq_question(), "sk", fake_translation_service(SK_MCQ_PAYLOAD)
        )
    )
    session.current_question_translation = record

    assert session_translation(session, "q_mcq") == record
    assert session_translation(session, "q_other") is None
    session.language = "cs"
    assert session_translation(session, "q_mcq") is None


# ── 2. What the answer is matched against (#126 seam) ────────────────────────


def test_slovak_true_false_answer_matches_deterministically():
    """#126's headline symptom. With Slovak options on the wire, "pravda" must
    resolve on the deterministic MCQ path — no LLM, no ambiguity. The evaluator's
    client is left unmocked on purpose: any network call would blow up the test."""
    record = asyncio.run(_record_for(tf_question(), SK_TF_PAYLOAD))
    view = translated_question_view(tf_question(), record)

    evaluator = AnswerEvaluator()
    assert asyncio.run(evaluator.evaluate("Pravda", view)) == ("correct", 1.0)
    assert asyncio.run(evaluator.evaluate("nepravda", view)) == ("incorrect", 0.0)


def test_spoken_slovak_option_text_matches_the_translated_option():
    """The corpus stores the correct answer as ENGLISH option text ("Paris"), so
    once options are Slovak the answer→key resolution can only work if the key was
    resolved at serve time. This pins that: "Paríž" scores, "Londýn" does not."""
    record = asyncio.run(_record_for(mcq_question(), SK_MCQ_PAYLOAD))
    view = translated_question_view(mcq_question(), record)

    # The evaluator still resolves correct_answer → key exactly as before.
    assert view.correct_answer == "a"
    assert view.possible_answers == MCQ_OPTIONS_SK

    evaluator = AnswerEvaluator()
    assert asyncio.run(evaluator.evaluate("Paríž", view)) == ("correct", 1.0)
    assert asyncio.run(evaluator.evaluate("Londýn", view)) == ("incorrect", 0.0)
    # Option keys keep working (iOS sends "a" for a tapped option).
    assert asyncio.run(evaluator.evaluate("a", view)) == ("correct", 1.0)


def test_correct_answer_stored_as_key_survives_translation():
    """Legacy rows store the key ("a") rather than the text. Key resolution must
    not regress into "translate the letter a"."""
    record = asyncio.run(_record_for(mcq_question(correct="a"), SK_MCQ_PAYLOAD))
    assert record["correct_answer_key"] == "a"
    assert record["correct_answer"] == "Paríž"


async def _record_for(question: Question, payload_return) -> dict:
    _, record = await translated_question_payload(
        question, "sk", fake_translation_service(payload_return)
    )
    return record


# ── 3. What the result screen says ───────────────────────────────────────────


def _flow_with(intents, question: Question) -> QuizFlowService:
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(return_value=intents)

    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=question)
    retriever.get_next_question = AsyncMock(return_value=None)  # end after one

    evaluator = MagicMock()
    evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))

    return QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=evaluator,
        tts_service=None,
        usage_tracker=None,
        translation_service=fake_translation_service(SK_MCQ_PAYLOAD),
    )


def _session_with_record(question: Question) -> QuizSession:
    session = sk_session(question.id)
    session.current_question_translation = asyncio.run(
        _record_for(question, SK_MCQ_PAYLOAD)
    )
    return session


def test_answer_result_carries_the_translated_explanation_and_answer():
    """The founder saw a Slovak question explained in English. The result quotes
    the record, so the explanation and the revealed answer are the same Slovak
    strings that were on screen — and no extra translation call is made."""
    question = mcq_question()
    session = _session_with_record(question)
    flow = _flow_with(
        [{"intent_type": "answer", "extracted_data": {"answer": "Paríž"}}], question
    )

    result = asyncio.run(flow.process_answer(session=session, answer_text="Paríž"))

    assert result.evaluation["explanation"] == EXPLANATION_SK
    assert result.evaluation["correct_answer"] == "Paríž"
    # The evaluator scored the question as the player saw it.
    scored = flow.answer_evaluator.evaluate.await_args.kwargs["question"]
    assert scored.possible_answers == MCQ_OPTIONS_SK
    flow.translation_service.translate_feedback.assert_not_awaited()


def test_skip_result_carries_the_translated_explanation_and_answer():
    """The skip path built its evaluation dict separately and was missed by every
    earlier translation fix — it must reveal Slovak too, not English."""
    question = mcq_question()
    session = _session_with_record(question)
    flow = _flow_with([{"intent_type": "skip", "extracted_data": {}}], question)

    result = asyncio.run(flow.process_answer(session=session, answer_text="skip"))

    assert result.evaluation["result"] == "skipped"
    assert result.evaluation["explanation"] == EXPLANATION_SK
    assert result.evaluation["correct_answer"] == "Paríž"


def test_english_session_result_is_untouched():
    """Zero behaviour change for English: no record, English explanation, and the
    legacy correct-answer path is not exercised (language == "en" short-circuits)."""
    question = mcq_question()
    session = sk_session(question.id)
    session.language = "en"
    flow = _flow_with(
        [{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}], question
    )

    result = asyncio.run(flow.process_answer(session=session, answer_text="Paris"))

    assert result.evaluation["explanation"] == EXPLANATION
    assert result.evaluation["correct_answer"] == "Paris"
    flow.translation_service.translate_question_payload.assert_not_awaited()


# ── 4. Fail-loud fallback ────────────────────────────────────────────────────


def make_service(store_url: str) -> TranslationService:
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService(store_url=store_url)


def mock_response(content: str):
    message = MagicMock()
    message.content = content
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]
    return response


@pytest.fixture
def service(tmp_path):
    return make_service(f"sqlite:///{tmp_path}/translations.db")


def test_payload_translation_failure_serves_english_and_reports(service):
    """A broken translation must degrade to English rather than break a quiz
    mid-drive — but silently degrading is how #132 stayed invisible, so the
    fallback fires exactly one Sentry event carrying the calibration detail."""
    service.client.chat.completions.create = AsyncMock(side_effect=Exception("429"))

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        payload, record = asyncio.run(
            translated_question_payload(
                mcq_question(), "sk", service, session_id="sess-x"
            )
        )

    assert record is None
    assert payload["question"] == STEM
    assert payload["possible_answers"] == MCQ_OPTIONS
    assert payload["explanation"] == EXPLANATION
    assert service.client.chat.completions.create.call_count == 3  # full retry budget
    mock_sentry.capture_message.assert_called_once()
    message = mock_sentry.capture_message.call_args[0][0]
    assert "#132" in message
    assert "api_error" in message
    assert "sess-x" in message


def test_payload_with_missing_or_renamed_options_is_rejected(service):
    """A translation that drops or renames an option key would break the answer→key
    resolution and silently mark every answer wrong — reject it, don't serve it."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(
            json.dumps({"question": STEM_SK, "options": {"a": "Paríž", "b": "Londýn"}})
        )
    )

    with patch("app.translation.translator.sentry_sdk") as mock_sentry:
        result = asyncio.run(
            service.translate_question_payload(
                {"question": STEM, "options": dict(MCQ_OPTIONS)}, "sk"
            )
        )

    assert result is None
    mock_sentry.capture_message.assert_called_once()
    assert "validation_reject" in mock_sentry.capture_message.call_args[0][0]


def test_payload_translation_is_cached_across_sessions(service):
    """Every Slovak player sees the same corpus; paying per session for the same
    payload is the cost bug #69 already solved for stems."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(json.dumps(SK_MCQ_PAYLOAD))
    )
    payload_in = {
        "question": STEM,
        "options": dict(MCQ_OPTIONS),
        "explanation": EXPLANATION,
    }

    first = asyncio.run(service.translate_question_payload(payload_in, "sk"))
    second = asyncio.run(service.translate_question_payload(payload_in, "sk"))

    assert first == second == SK_MCQ_PAYLOAD
    assert service.client.chat.completions.create.call_count == 1
