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
from app.session.manager import SessionConflict, SessionManager
from app.session.store import MemorySessionStore
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question

pytestmark = pytest.mark.asyncio


class TestSessionManagerDeepCopy:
    """Verify get_session() returns isolated copies, not shared references."""

    async def test_get_session_returns_copy_not_reference(self):
        """Mutating a returned session must not affect the stored session."""
        manager = SessionManager()
        session = await manager.create_session(max_questions=5, difficulty="easy")
        session_id = session.session_id

        # Get two independent copies
        copy_a = await manager.get_session(session_id)
        copy_b = await manager.get_session(session_id)

        # Mutate copy_a
        copy_a.current_question_id = "q_mutated"
        copy_a.phase = "finished"
        copy_a.asked_question_ids.append("q_mutated")

        # copy_b should be unaffected
        assert copy_b.current_question_id != "q_mutated"
        assert copy_b.phase != "finished"
        assert "q_mutated" not in copy_b.asked_question_ids

    async def test_get_session_mutation_does_not_affect_stored(self):
        """Mutating a returned session must not affect a subsequent get_session() call."""
        manager = SessionManager()
        session = await manager.create_session(max_questions=10, difficulty="medium")
        session_id = session.session_id

        # Get and mutate
        fetched = await manager.get_session(session_id)
        fetched.current_question_id = "q_race_condition"
        fetched.score = 999.0

        # Fresh get should return original state
        fresh = await manager.get_session(session_id)
        assert fresh.current_question_id is None
        assert fresh.score == 0.0

    async def test_update_session_writes_back_correctly(self):
        """update_session() should persist the caller's changes."""
        manager = SessionManager()
        session = await manager.create_session(max_questions=5)
        session_id = session.session_id

        # Get, modify, write back
        copy = await manager.get_session(session_id)
        copy.current_question_id = "q_123"
        copy.phase = "asking"
        await manager.update_session(copy)

        # New get should reflect the update
        refreshed = await manager.get_session(session_id)
        assert refreshed.current_question_id == "q_123"
        assert refreshed.phase == "asking"

    async def test_concurrent_readers_get_independent_snapshots(self):
        """Simulates the race: two requests read session, one mutates before the other evaluates."""
        manager = SessionManager()
        session = await manager.create_session(max_questions=10)
        session_id = session.session_id

        # Set up initial question
        setup = await manager.get_session(session_id)
        setup.current_question_id = "q_question_1"
        setup.phase = "asking"
        await manager.update_session(setup)

        # Request A reads session (about to evaluate q_question_1)
        request_a_session = await manager.get_session(session_id)
        evaluated_question_id = request_a_session.current_question_id

        # Request B reads and advances to next question (parallel fetch)
        request_b_session = await manager.get_session(session_id)
        request_b_session.current_question_id = "q_question_2"
        request_b_session.asked_question_ids.append("q_question_2")
        await manager.update_session(request_b_session)

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

    async def _manager_at_graded_question(self) -> tuple[SessionManager, str]:
        manager = SessionManager()
        sid = (await manager.create_session(max_questions=10)).session_id
        session = await manager.get_session(sid)
        session.phase = SessionPhase.ASKING
        session.current_question_id = self.GRADED
        session.asked_question_ids = [self.GRADED]
        await manager.update_session(session)
        return manager, sid

    def _flow(self, manager: SessionManager, intents) -> QuizFlowService:
        input_parser = MagicMock()
        input_parser.parse = AsyncMock(return_value=intents)

        retriever = MagicMock()
        retriever.get = AsyncMock(return_value=self._question(self.GRADED))
        retriever.get_next_question = AsyncMock(return_value=self._question(self.NEXT))

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

    async def test_answer_evaluation_names_the_graded_question_not_the_next_one(self):
        manager, sid = await self._manager_at_graded_question()
        flow = self._flow(
            manager, [{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
        )

        result = await flow.process_answer(
            session=await manager.get_session(sid), answer_text="Paris"
        )

        assert result.evaluation.question_id == self.GRADED
        assert result.evaluation.result == "correct"
        # Non-vacuous: the session really did move on, and the client is being
        # handed the next question in the same response — so "graded" and
        # "current" are genuinely two different ids at this point.
        assert (await manager.get_session(sid)).current_question_id == self.NEXT
        assert result.next_question_dict["id"] == self.NEXT

    async def test_skip_evaluation_names_the_skipped_question(self):
        """A skip is graded state too, and builds its own evaluation dict — it
        must carry the id of the question that was skipped, not the one served
        in its place."""
        manager, sid = await self._manager_at_graded_question()
        flow = self._flow(manager, [])  # literal "skip" never reaches the parser

        result = await flow.process_answer(
            session=await manager.get_session(sid), answer_text="skip"
        )

        assert result.evaluation.question_id == self.GRADED
        assert result.evaluation.result == "skipped"
        assert result.evaluation.points == 0.0
        assert (await manager.get_session(sid)).current_question_id == self.NEXT

    async def test_graded_id_is_remembered_on_the_session_for_a_retry(self):
        """The same id is snapshotted onto ``session.last_evaluation`` before the
        advance — that is what lets a re-sent submit be recognised as a retry of
        the graded question instead of being scored against the next one."""
        manager, sid = await self._manager_at_graded_question()
        flow = self._flow(
            manager, [{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
        )

        await flow.process_answer(
            session=await manager.get_session(sid), answer_text="Paris"
        )

        stored = await manager.get_session(sid)
        assert stored.last_evaluation is not None
        assert stored.last_evaluation.question_id == self.GRADED
        assert stored.current_question_id == self.NEXT


class TestSessionPersistence:
    """A session lives in the shared store, not in one manager's memory (#207.20).

    A request can land on any machine, so a second manager over the same store
    (a restarted or sibling machine) must see exactly what the first wrote.
    """

    async def test_session_visible_to_a_fresh_manager_on_the_same_store(self):
        store = MemorySessionStore()
        manager_a = SessionManager(store=store)
        session = await manager_a.create_session(max_questions=5, difficulty="hard")
        sid = session.session_id

        manager_b = SessionManager(store=store)
        restored = await manager_b.get_session(sid)
        assert restored is not None
        assert restored.max_questions == 5
        assert restored.current_difficulty == "hard"

    async def test_updated_session_is_visible_to_a_fresh_manager(self):
        store = MemorySessionStore()
        manager_a = SessionManager(store=store)
        session = await manager_a.create_session(max_questions=10)
        sid = session.session_id

        copy = await manager_a.get_session(sid)
        copy.phase = "asking"
        copy.score = 3.5
        copy.question_number = 4
        await manager_a.update_session(copy)

        restored = await SessionManager(store=store).get_session(sid)
        assert restored.phase == "asking"
        assert restored.score == 3.5
        assert restored.question_number == 4

    async def test_deleted_session_is_gone_for_a_fresh_manager(self):
        store = MemorySessionStore()
        manager_a = SessionManager(store=store)
        sid = (await manager_a.create_session()).session_id
        await manager_a.delete_session(sid)

        assert await SessionManager(store=store).get_session(sid) is None

    async def test_stale_copy_write_is_refused_not_silently_applied(self):
        """Two requests read the same version; the second writer must fail
        loudly instead of undoing the first one's advance."""
        manager = SessionManager()
        sid = (await manager.create_session()).session_id
        first = await manager.get_session(sid)
        stale = await manager.get_session(sid)

        first.score = 2.0
        await manager.update_session(first)

        stale.score = 99.0
        with pytest.raises(SessionConflict):
            await manager.update_session(stale)
        assert (await manager.get_session(sid)).score == 2.0

    async def test_local_lock_entry_is_dropped_once_nobody_uses_it(self):
        """The per-session lock map must not grow with every session ever seen."""
        manager = SessionManager()
        sid = (await manager.create_session()).session_id
        async with manager.session_lock(sid):
            assert sid in manager._local
        assert sid not in manager._local
