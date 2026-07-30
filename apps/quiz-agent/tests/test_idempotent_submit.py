"""#133 1a: answer submits are question-scoped and idempotent.

Two audited defects shared one root cause — the submit API was neither
question-scoped nor idempotent, while the client re-sends:

- ``TransientRetry`` re-POSTs on ``timedOut``/``networkConnectionLost``. When the
  server had already processed the submit and only the response was lost, the
  retry was graded against the NEXT, unseen question and charged a second
  freemium question (real money, and a verdict for a question the player never
  saw).
- Editing a Whisper transcript throws away the completed evaluation and re-POSTs
  the corrected text to a session the server has already advanced — same two
  effects.

The fix: the client sends the ``question_id`` it is answering, and the server
replays / re-grades / refuses. These tests pin the invariant the money and the
grading depend on: **the same question_id never charges quota twice and never
advances the session twice**, and a text that was edited is re-graded against the
question it was written for, not the one that came after it.
"""

from __future__ import annotations

import asyncio
from typing import Any, Dict, List, Optional
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api import deps
from app.api.routes import quiz as quiz_routes
from app.quiz.flow import QuestionMismatch, QuizFlowService
from app.rate_limit import limiter
from quiz_shared.models.participant import Participant
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

_SESSION_ID = "s_idem"
_Q1 = "q_first"
_Q2 = "q_second"


def _question(qid: str, text: str = "What is the capital of France?") -> Question:
    return Question(
        id=qid,
        question=text,
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _roundtrip(session: QuizSession) -> QuizSession:
    return QuizSession.model_validate_json(session.model_dump_json())


class _FakeSessionManager:
    """Stands in for SessionManager: isolated copies out, writes recorded.

    Copies travel through JSON exactly as the real manager's write-through
    persistence does, so a test that reads a stored session back also proves the
    new nested ``last_evaluation`` survives the session blob — a retry that
    arrives after a process restart depends on that.
    """

    def __init__(self, session: QuizSession):
        self.stored = _roundtrip(session)
        self.writes: List[QuizSession] = []
        self._lock = asyncio.Lock()

    def get_session(self, session_id: str) -> QuizSession:
        return _roundtrip(self.stored)

    def update_session(self, session: QuizSession) -> bool:
        self.stored = _roundtrip(session)
        self.writes.append(self.stored)
        return True

    def session_lock(self, session_id: str) -> asyncio.Lock:
        return self._lock


def _session(**overrides: Any) -> QuizSession:
    base: Dict[str, Any] = dict(
        session_id=_SESSION_ID,
        user_id="u_1",
        phase=SessionPhase.ASKING,
        current_question_id=_Q1,
        asked_question_ids=[_Q1],
        max_questions=10,
        participants=[Participant(participant_id="p_1", display_name="Player")],
    )
    base.update(overrides)
    return QuizSession(**base)


def _flow(
    manager: _FakeSessionManager,
    questions: Optional[Dict[str, Question]] = None,
    usage_tracker: Optional[MagicMock] = None,
) -> QuizFlowService:
    """A real QuizFlowService over mocked collaborators.

    The parser echoes the submitted text back as the answer and the evaluator
    grades "Paris" correct (1.0) and anything else incorrect (0.0), so a test can
    tell a replayed verdict from a re-graded one by its score alone.
    """
    questions = questions or {_Q1: _question(_Q1), _Q2: _question(_Q2)}

    async def _parse(user_input: str, current_question: str, phase: Any):
        if not user_input.strip():
            return []
        return [{"intent_type": "answer", "extracted_data": {"answer": user_input}}]

    async def _evaluate(user_answer: str, question: Question, question_text: str):
        return (
            ("correct", 1.0) if user_answer.strip() == "Paris" else ("incorrect", 0.0)
        )

    input_parser = MagicMock()
    input_parser.parse = AsyncMock(side_effect=_parse)

    retriever = MagicMock()
    retriever.get = MagicMock(side_effect=lambda qid: questions.get(qid))
    retriever.get_next_question = MagicMock(return_value=questions[_Q2])

    evaluator = MagicMock()
    evaluator.evaluate = AsyncMock(side_effect=_evaluate)

    if usage_tracker is None:
        usage_tracker = MagicMock()
        usage_tracker.check_limit = AsyncMock(return_value=(True, 5, None))
        usage_tracker.record_question = AsyncMock()

    return QuizFlowService(
        session_manager=manager,
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=evaluator,
        tts_service=None,
        usage_tracker=usage_tracker,
        translation_service=None,
    )


async def _submit(
    flow: QuizFlowService,
    manager: _FakeSessionManager,
    text: str,
    question_id: Optional[str] = None,
):
    """One submit, the way the route does it: fresh copy in, FlowResult out."""
    session = manager.get_session(_SESSION_ID)
    return await flow.process_answer(
        session=session, answer_text=text, submitted_question_id=question_id
    )


# ── Replay: a retry whose original response was lost ─────────────────────────


async def test_retry_of_a_graded_submission_replays_it_and_charges_nothing():
    """The tunnel case: the server graded the answer, the response never arrived,
    the client retried the identical text.

    The retry must return the SAME verdict for the SAME question — not a verdict
    for the question the session has since moved to — and must not spend a second
    freemium question, a second evaluator call, or advance again. Every one of
    those was happening before the fix.
    """
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    first = await _submit(flow, manager, "Paris", question_id=_Q1)
    assert manager.stored.current_question_id == _Q2  # advanced once
    evaluator_calls = flow.answer_evaluator.evaluate.await_count
    writes = len(manager.writes)

    replay = await _submit(flow, manager, "Paris", question_id=_Q1)

    assert replay.evaluation == first.evaluation
    assert replay.evaluation["question_id"] == _Q1
    assert replay.feedback_received == first.feedback_received
    # The question the client should be showing comes back unchanged.
    assert replay.next_question_dict["id"] == _Q2

    # Money + state: nothing re-evaluated, nothing charged, nothing advanced,
    # nothing even written.
    assert flow.answer_evaluator.evaluate.await_count == evaluator_calls
    flow.usage_tracker.record_question.assert_awaited_once()
    assert manager.stored.current_question_id == _Q2
    assert manager.stored.asked_question_ids == [_Q1, _Q2]
    assert len(manager.writes) == writes
    assert manager.stored.participants[0].score == 1.0
    assert manager.stored.participants[0].answered_count == 1


async def test_a_skip_is_recorded_and_replayed_as_a_skip():
    """A skipped question is graded state too: retrying the skip must replay
    "skipped" for that question, not skip the next one as well."""
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    first = await _submit(flow, manager, "skip", question_id=_Q1)
    assert first.evaluation["result"] == "skipped"
    assert manager.stored.last_evaluation.question_id == _Q1
    assert manager.stored.last_evaluation.answered_count_delta == 0

    replay = await _submit(flow, manager, "skip", question_id=_Q1)

    assert replay.evaluation == first.evaluation
    assert manager.stored.asked_question_ids == [_Q1, _Q2]
    flow.usage_tracker.record_question.assert_awaited_once()


# ── Re-grade: the edited transcript ──────────────────────────────────────────


async def test_edited_transcript_is_regraded_against_the_question_it_answers():
    """Whisper heard "Paris", the player corrected it to "Lyon" and re-submitted.

    Before the fix the corrected text was graded against the next, unseen
    question. It must be graded against the question the player was looking at,
    with no second quota charge and no second advance.
    """
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    await _submit(flow, manager, "Paris", question_id=_Q1)

    regrade = await _submit(flow, manager, "Lyon", question_id=_Q1)

    assert regrade.evaluation["question_id"] == _Q1
    assert regrade.evaluation["result"] == "incorrect"
    assert regrade.evaluation["user_answer"] == "Lyon"
    # Still on the question the first submit advanced to — no double advance.
    assert manager.stored.current_question_id == _Q2
    assert manager.stored.asked_question_ids == [_Q1, _Q2]
    flow.usage_tracker.record_question.assert_awaited_once()
    # The replacement is what a further retry replays.
    assert manager.stored.last_evaluation.submitted_text == "Lyon"


async def test_regrade_replaces_the_previous_score_instead_of_adding_to_it():
    """The first verdict's points were already banked. A re-grade must reverse
    them, or an edited answer would leave the player credited twice (or credited
    for a verdict that no longer stands)."""
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    await _submit(flow, manager, "Paris", question_id=_Q1)
    assert manager.stored.participants[0].score == 1.0
    assert manager.stored.participants[0].answered_count == 1

    await _submit(flow, manager, "Lyon", question_id=_Q1)

    assert manager.stored.participants[0].score == 0.0
    assert manager.stored.participants[0].answered_count == 1


async def test_regrade_scores_against_the_strings_the_player_actually_saw():
    """#132 D held for the first submit only: the session's translation record is
    overwritten by the next question, so a re-grade that re-read it would score a
    Slovak answer against English options.

    The record is kept with the graded submission for exactly this reason.
    """
    sk_record = {
        "question_id": _Q1,
        "language": "sk",
        "question": "Aké je hlavné mesto Francúzska?",
        "possible_answers": None,
        "explanation": None,
        "headline_answer": None,
        "correct_answer": "Paríž",
        "correct_answer_key": None,
    }
    manager = _FakeSessionManager(
        _session(language="sk", current_question_translation=sk_record)
    )
    flow = _flow(manager)

    await _submit(flow, manager, "Paris", question_id=_Q1)
    # The advance replaced the record (no translation service → None).
    assert manager.stored.current_question_translation is None

    await _submit(flow, manager, "Nice", question_id=_Q1)

    graded_with = flow.answer_evaluator.evaluate.await_args.kwargs["question"]
    assert graded_with.question == "Aké je hlavné mesto Francúzska?"
    assert graded_with.correct_answer == "Paríž"


# ── Refusal: an id this session cannot grade ─────────────────────────────────


async def test_out_of_step_question_id_is_refused_without_touching_the_session():
    """A question_id that is neither current nor last-graded means the client is
    out of step. Grading it would score a question the player never saw, so it is
    refused — before any evaluation, any charge, and any mutation."""
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    with pytest.raises(QuestionMismatch) as excinfo:
        await _submit(flow, manager, "Paris", question_id="q_never_served")

    assert excinfo.value.current_question_id == _Q1
    assert manager.writes == []
    assert manager.stored.current_question_id == _Q1
    assert manager.stored.last_evaluation is None
    flow.answer_evaluator.evaluate.assert_not_awaited()
    flow.usage_tracker.record_question.assert_not_awaited()


# ── Legacy client: no question_id at all ────────────────────────────────────


async def test_submit_without_question_id_grades_the_current_question_as_before():
    """Backward compatibility: a client that sends no question_id keeps the
    pre-#133 behaviour — graded against the current question, advanced, charged.
    Nothing about the fix may gate on the new field being present."""
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    first = await _submit(flow, manager, "Paris")
    second = await _submit(flow, manager, "Paris")

    assert first.evaluation["question_id"] == _Q1
    assert second.evaluation["question_id"] == _Q2  # graded the advanced question
    assert flow.usage_tracker.record_question.await_count == 2


# ── The lone preference change (audit follow-up to the same flow) ────────────


async def test_a_preference_stated_alone_is_persisted():
    """A preference stated alone ("no more geography") parsed and mutated the
    session — then the ghost-question guard returned before ``update_session`` and
    threw the mutation away, so the player kept getting the topic they had just
    rejected.

    It must be persisted. It is still not an answer: nothing advances and no
    freemium question is charged.
    """
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)
    flow.input_parser.parse = AsyncMock(
        return_value=[
            {
                "intent_type": "preference_change",
                "extracted_data": {
                    "avoid_topics": ["geography"],
                    "difficulty": "harder",
                },
            }
        ]
    )

    result = await _submit(flow, manager, "no more geography, make it harder")

    assert result.evaluation is None  # the route still surfaces this as a 400
    assert manager.stored.disliked_topics == ["geography"]
    assert manager.stored.current_difficulty == "hard"
    assert manager.stored.current_question_id == _Q1
    assert manager.stored.asked_question_ids == [_Q1]
    assert manager.stored.last_evaluation is None
    flow.usage_tracker.record_question.assert_not_awaited()


async def test_an_unparseable_utterance_still_persists_nothing():
    """The guard's original job stays intact: an utterance that changed nothing
    must not write the session at all (that early return is what keeps a
    non-answer from burning a question)."""
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)
    flow.input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "rating", "extracted_data": {"rating": 5}}]
    )

    result = await _submit(flow, manager, "that was fun")

    assert result.evaluation is None
    assert manager.writes == []


# ── Route layer: the refusal the client sees ─────────────────────────────────


@pytest_asyncio.fixture
async def client():
    limiter.reset()
    manager = _FakeSessionManager(_session())
    flow = _flow(manager)

    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(quiz_routes.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_session_manager] = lambda: manager
    app.dependency_overrides[deps.get_quiz_flow] = lambda: flow

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c, manager, flow


async def test_route_refuses_an_out_of_step_question_id_with_409(client):
    """The client needs to tell "you are out of step, resync" apart from "retry
    me" (503) and "I could not understand you" (400) — a 409 carrying the code and
    the current question id is that signal."""
    c, manager, _flow_under_test = client

    resp = await c.post(
        f"/api/v1/sessions/{_SESSION_ID}/input",
        json={"input": "Paris", "question_id": "q_never_served"},
    )

    assert resp.status_code == 409
    assert resp.json()["detail"] == {
        "code": "question_mismatch",
        "current_question_id": _Q1,
    }
    assert manager.writes == []


async def test_route_replays_a_retried_submit_end_to_end(client):
    """The whole point, through the real route: submitting the same question_id
    twice returns the same verdict, pays for one evaluation, and charges one
    freemium question."""
    c, manager, flow = client
    body = {"input": "Paris", "question_id": _Q1}

    first = await c.post(f"/api/v1/sessions/{_SESSION_ID}/input", json=body)
    second = await c.post(f"/api/v1/sessions/{_SESSION_ID}/input", json=body)

    assert first.status_code == 200 and second.status_code == 200
    assert second.json()["evaluation"] == first.json()["evaluation"]
    assert second.json()["current_question"]["id"] == _Q2
    assert manager.stored.asked_question_ids == [_Q1, _Q2]
    assert flow.answer_evaluator.evaluate.await_count == 1
    flow.usage_tracker.record_question.assert_awaited_once()
