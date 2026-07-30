"""Tests for SessionManager deep-copy isolation, evaluation flow, and persistence."""

import sys
import os
from unittest.mock import AsyncMock, MagicMock

import pytest

# Add shared package to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.quiz.flow import QuizFlowService
from app.session.manager import SessionManager
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question


class StubSQLClient:
    """Minimal in-memory stub for SQLClient session persistence methods.

    Avoids importing the real SQLClient which pulls in chromadb.
    """

    def __init__(self):
        self._store: dict[
            str, tuple[str, bool]
        ] = {}  # session_id -> (data_json, is_active)

    def save_session(self, session_id: str, data_json: str) -> bool:
        self._store[session_id] = (data_json, True)
        return True

    def deactivate_session(self, session_id: str) -> bool:
        if session_id in self._store:
            data_json, _ = self._store[session_id]
            self._store[session_id] = (data_json, False)
        return True

    def load_active_sessions(self) -> list[tuple[str, str]]:
        return [(sid, data) for sid, (data, active) in self._store.items() if active]


class TestSessionManagerDeepCopy:
    """Verify get_session() returns isolated copies, not shared references."""

    def test_get_session_returns_copy_not_reference(self):
        """Mutating a returned session must not affect the stored session."""
        manager = SessionManager()
        session = manager.create_session(max_questions=5, difficulty="easy")
        session_id = session.session_id

        # Get two independent copies
        copy_a = manager.get_session(session_id)
        copy_b = manager.get_session(session_id)

        # Mutate copy_a
        copy_a.current_question_id = "q_mutated"
        copy_a.phase = "finished"
        copy_a.asked_question_ids.append("q_mutated")

        # copy_b should be unaffected
        assert copy_b.current_question_id != "q_mutated"
        assert copy_b.phase != "finished"
        assert "q_mutated" not in copy_b.asked_question_ids

    def test_get_session_mutation_does_not_affect_stored(self):
        """Mutating a returned session must not affect a subsequent get_session() call."""
        manager = SessionManager()
        session = manager.create_session(max_questions=10, difficulty="medium")
        session_id = session.session_id

        # Get and mutate
        fetched = manager.get_session(session_id)
        fetched.current_question_id = "q_race_condition"
        fetched.score = 999.0

        # Fresh get should return original state
        fresh = manager.get_session(session_id)
        assert fresh.current_question_id is None
        assert fresh.score == 0.0

    def test_update_session_writes_back_correctly(self):
        """update_session() should persist the caller's changes."""
        manager = SessionManager()
        session = manager.create_session(max_questions=5)
        session_id = session.session_id

        # Get, modify, write back
        copy = manager.get_session(session_id)
        copy.current_question_id = "q_123"
        copy.phase = "asking"
        manager.update_session(copy)

        # New get should reflect the update
        refreshed = manager.get_session(session_id)
        assert refreshed.current_question_id == "q_123"
        assert refreshed.phase == "asking"

    def test_concurrent_readers_get_independent_snapshots(self):
        """Simulates the race: two requests read session, one mutates before the other evaluates."""
        manager = SessionManager()
        session = manager.create_session(max_questions=10)
        session_id = session.session_id

        # Set up initial question
        setup = manager.get_session(session_id)
        setup.current_question_id = "q_question_1"
        setup.phase = "asking"
        manager.update_session(setup)

        # Request A reads session (about to evaluate q_question_1)
        request_a_session = manager.get_session(session_id)
        evaluated_question_id = request_a_session.current_question_id

        # Request B reads and advances to next question (parallel fetch)
        request_b_session = manager.get_session(session_id)
        request_b_session.current_question_id = "q_question_2"
        request_b_session.asked_question_ids.append("q_question_2")
        manager.update_session(request_b_session)

        # Request A should still see q_question_1 (its snapshot is isolated)
        assert evaluated_question_id == "q_question_1"
        assert request_a_session.current_question_id == "q_question_1"


class TestEvaluationQuestionId:
    """The evaluation handed back to the client must name the question it GRADED.

    iOS validates the verdict against the question on screen before rendering it,
    so a wrongly-tagged verdict is shown against the wrong question. The trap is
    ordering: by the time ``process_answer`` returns, the session has already
    advanced to the next question, so ``question_id`` must be the id captured
    before the advance — using the live ``session.current_question_id`` at
    response-build time would tag every verdict with the *next*, unanswered
    question.

    Driven through the real ``SessionManager`` (this module's subject) and the
    real ``QuizFlowService``: the stored session genuinely moving on is what
    makes these assertions non-vacuous. Scope note — the replay / re-grade side
    of this same field is covered by ``test_idempotent_submit.py``; what is
    pinned here is the FIRST submit of a question (no ``submitted_question_id``,
    i.e. the legacy-client path) and the skip intent, which build the evaluation
    dict at two separate sites in ``flow.py``.
    """

    GRADED = "q_graded"
    NEXT = "q_next"

    def _question(self, qid: str) -> Question:
        return Question(
            id=qid,
            question="What is the capital of France?",
            type="text",
            correct_answer="Paris",
            topic="Geography",
            category="general",
            difficulty="medium",
        )

    def _manager_at_graded_question(self) -> tuple[SessionManager, str]:
        manager = SessionManager()
        sid = manager.create_session(max_questions=10).session_id
        session = manager.get_session(sid)
        session.phase = SessionPhase.ASKING
        session.current_question_id = self.GRADED
        session.asked_question_ids = [self.GRADED]
        manager.update_session(session)
        return manager, sid

    def _flow(self, manager: SessionManager, intents) -> QuizFlowService:
        input_parser = MagicMock()
        input_parser.parse = AsyncMock(return_value=intents)

        retriever = MagicMock()
        retriever.get = MagicMock(return_value=self._question(self.GRADED))
        retriever.get_next_question = MagicMock(return_value=self._question(self.NEXT))

        evaluator = MagicMock()
        evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))

        return QuizFlowService(
            session_manager=manager,
            input_parser=input_parser,
            question_retriever=retriever,
            answer_evaluator=evaluator,
            tts_service=None,
            usage_tracker=None,
            translation_service=None,
        )

    @pytest.mark.asyncio
    async def test_answer_evaluation_names_the_graded_question_not_the_next_one(self):
        manager, sid = self._manager_at_graded_question()
        flow = self._flow(
            manager, [{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
        )

        result = await flow.process_answer(
            session=manager.get_session(sid), answer_text="Paris"
        )

        assert result.evaluation["question_id"] == self.GRADED
        assert result.evaluation["result"] == "correct"
        # Non-vacuous: the session really did move on, and the client is being
        # handed the next question in the same response — so "graded" and
        # "current" are genuinely two different ids at this point.
        assert manager.get_session(sid).current_question_id == self.NEXT
        assert result.next_question_dict["id"] == self.NEXT

    @pytest.mark.asyncio
    async def test_skip_evaluation_names_the_skipped_question(self):
        """A skip is graded state too, and builds its own evaluation dict — it
        must carry the id of the question that was skipped, not the one served
        in its place."""
        manager, sid = self._manager_at_graded_question()
        flow = self._flow(manager, [])  # literal "skip" never reaches the parser

        result = await flow.process_answer(
            session=manager.get_session(sid), answer_text="skip"
        )

        assert result.evaluation["question_id"] == self.GRADED
        assert result.evaluation["result"] == "skipped"
        assert result.evaluation["points"] == 0.0
        assert manager.get_session(sid).current_question_id == self.NEXT

    @pytest.mark.asyncio
    async def test_graded_id_is_remembered_on_the_session_for_a_retry(self):
        """The same id is snapshotted onto ``session.last_evaluation`` before the
        advance — that is what lets a re-sent submit be recognised as a retry of
        the graded question instead of being scored against the next one."""
        manager, sid = self._manager_at_graded_question()
        flow = self._flow(
            manager, [{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
        )

        await flow.process_answer(session=manager.get_session(sid), answer_text="Paris")

        stored = manager.get_session(sid)
        assert stored.last_evaluation is not None
        assert stored.last_evaluation.question_id == self.GRADED
        assert stored.current_question_id == self.NEXT


class TestSessionPersistence:
    """Verify sessions survive a simulated restart via SQLite persistence."""

    def test_session_survives_restart(self):
        """Create session in manager A, reload in manager B — session survives."""
        sql = StubSQLClient()
        manager_a = SessionManager(sql_client=sql)
        session = manager_a.create_session(max_questions=5, difficulty="hard")
        sid = session.session_id

        # Simulate restart: new manager, same SQL client
        manager_b = SessionManager(sql_client=sql)
        reloaded = manager_b.reload_active_sessions()
        assert reloaded == 1

        restored = manager_b.get_session(sid)
        assert restored is not None
        assert restored.max_questions == 5
        assert restored.current_difficulty == "hard"

    def test_updated_session_persists(self):
        """Updates to session state are reflected after reload."""
        sql = StubSQLClient()
        manager_a = SessionManager(sql_client=sql)
        session = manager_a.create_session(max_questions=10)
        sid = session.session_id

        # Advance quiz state
        copy = manager_a.get_session(sid)
        copy.phase = "asking"
        copy.score = 3.5
        copy.question_number = 4
        manager_a.update_session(copy)

        # Reload
        manager_b = SessionManager(sql_client=sql)
        manager_b.reload_active_sessions()
        restored = manager_b.get_session(sid)
        assert restored.phase == "asking"
        assert restored.score == 3.5
        assert restored.question_number == 4

    def test_deleted_session_not_reloaded(self):
        """Deleted sessions should not be reloaded."""
        sql = StubSQLClient()
        manager_a = SessionManager(sql_client=sql)
        session = manager_a.create_session()
        sid = session.session_id
        manager_a.delete_session(sid)

        manager_b = SessionManager(sql_client=sql)
        reloaded = manager_b.reload_active_sessions()
        assert reloaded == 0
        assert manager_b.get_session(sid) is None

    def test_no_sql_client_works_fine(self):
        """SessionManager without sql_client should work as before (in-memory only)."""
        manager = SessionManager()
        session = manager.create_session(max_questions=5)
        assert manager.get_session(session.session_id) is not None
