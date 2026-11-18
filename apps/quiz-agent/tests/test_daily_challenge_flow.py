"""#205 in the quiz flow: a daily-challenge answer gets its crowd strip, the
host's crowd sentence rides on the SAME feedback utterance (no extra TTS call —
ElevenLabs is 98 % of spend), the first verdict is recorded, the round end is
recorded, and the free monthly quota is never touched."""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.daily_challenge.schemas import CrowdStrip
from app.quiz.flow import QuizFlowService
from app.retrieval.question_retriever import QuestionRetriever
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio


def _question(qid="q1") -> Question:
    return Question(
        id=qid,
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _session(asked, max_questions=5) -> QuizSession:
    return QuizSession(
        session_id="s_daily",
        user_id="anon-1",
        phase=SessionPhase.ASKING,
        language="en",
        current_question_id=asked[-1],
        asked_question_ids=list(asked),
        max_questions=max_questions,
        daily_challenge_date="2026-10-15",
        fixed_question_ids=["q1", "q2", "q3", "q4", "q5"],
    )


def _flow(daily, usage=None):
    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=_question())
    retriever.get_next_question = AsyncMock(return_value=_question("q2"))
    evaluator = MagicMock()
    evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    parser = MagicMock()
    parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
    )
    tts = MagicMock()
    tts.synthesize = AsyncMock(return_value=b"opus")
    tts.synthesize_question = AsyncMock(return_value=b"opus")
    flow = QuizFlowService(
        session_manager=AsyncMock(),
        input_parser=parser,
        question_retriever=retriever,
        answer_evaluator=evaluator,
        tts_service=tts,
        usage_tracker=usage,
        translation_service=None,
        daily_challenge=daily,
    )
    return flow, tts


def _daily(line="Only 1 of 3 knew that."):
    daily = MagicMock()
    daily.answer_strip = AsyncMock(
        return_value=(
            CrowdStrip(kind="rare", text="1 of 3 knew.", others=3, knew=1),
            line,
        )
    )
    daily.record_answer = AsyncMock()
    daily.finish = AsyncMock()
    return daily


async def test_crowd_line_is_appended_to_the_one_feedback_utterance():
    daily = _daily()
    usage = MagicMock()
    usage.check_limit = AsyncMock(return_value=(False, 0, None))
    usage.record_question = AsyncMock()
    flow, tts = _flow(daily, usage)

    result = await flow.process_answer(
        session=_session(["q1"]), answer_text="Paris", include_audio=True
    )

    assert tts.synthesize.await_count == 1
    spoken = tts.synthesize.await_args.kwargs["text"]
    assert spoken.endswith("Only 1 of 3 knew that.")
    assert result.crowd.text == "1 of 3 knew."
    daily.record_answer.assert_awaited_once()
    assert daily.record_answer.await_args.args[1:] == ("q1", "correct")
    # Quota: an exhausted free tier must not end the daily challenge.
    usage.check_limit.assert_not_awaited()
    usage.record_question.assert_not_awaited()
    assert result.usage_limit_error is None


async def test_quiet_answer_speaks_only_the_verdict():
    flow, tts = _flow(_daily(line=None))
    await flow.process_answer(
        session=_session(["q1"]), answer_text="Paris", include_audio=True
    )
    assert tts.synthesize.await_args.kwargs["text"] == "Correct! The answer is Paris."


async def test_last_question_records_the_round_end():
    daily = _daily()
    flow, _ = _flow(daily)
    result = await flow.process_answer(
        session=_session(["q1", "q2", "q3", "q4", "q5"]), answer_text="Paris"
    )
    assert result.quiz_finished
    daily.finish.assert_awaited_once()


async def test_a_crowd_failure_never_loses_the_verdict():
    daily = _daily()
    daily.answer_strip = AsyncMock(side_effect=RuntimeError("db down"))
    flow, tts = _flow(daily)
    result = await flow.process_answer(
        session=_session(["q1"]), answer_text="Paris", include_audio=True
    )
    assert result.evaluation.result == "correct"
    assert result.crowd is None


async def test_fixed_set_plays_in_order_ignoring_the_players_history():
    store = MagicMock()
    store.get = AsyncMock(
        side_effect=lambda qid: None if qid == "q2" else _question(qid)
    )
    retriever = QuestionRetriever(question_store=store)
    session = _session(["q1"])
    session.client_excluded_ids = ["q3"]
    nxt = await retriever.get_next_question(session, client_excluded_ids=["q3"])
    # q2 vanished from the corpus → skipped, q3 is served despite the history.
    assert nxt.id == "q3"


async def test_a_replayed_response_keeps_its_crowd_strip():
    """A lost response re-sent with the same text replays the stored verdict;
    the strip must come back with it, not vanish from the result card."""
    daily = _daily()
    flow, _ = _flow(daily)
    session = _session(["q1"])
    first = await flow.process_answer(
        session=session, answer_text="Paris", submitted_question_id="q1"
    )
    replay = await flow.process_answer(
        session=session, answer_text="Paris", submitted_question_id="q1"
    )
    assert replay.message == "Answer already processed"
    assert replay.crowd == first.crowd
    daily.answer_strip.assert_awaited_once()


async def test_an_edited_transcript_regrades_the_recorded_verdict():
    daily = _daily()
    flow, _ = _flow(daily)
    session = _session(["q1"])
    await flow.process_answer(
        session=session, answer_text="Paris", submitted_question_id="q1"
    )
    await flow.process_answer(
        session=session, answer_text="Paris, France", submitted_question_id="q1"
    )
    assert daily.answer_strip.await_args.kwargs["regrade"] is True
    assert daily.record_answer.await_args.kwargs["regrade"] is True
