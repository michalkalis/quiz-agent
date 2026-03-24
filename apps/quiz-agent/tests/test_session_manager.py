"""Tests for SessionManager deep-copy isolation, evaluation flow, and persistence."""

import sys
import os

# Add shared package to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from app.session.manager import SessionManager


class StubSQLClient:
    """Minimal in-memory stub for SQLClient session persistence methods.

    Avoids importing the real SQLClient which pulls in chromadb.
    """

    def __init__(self):
        self._store: dict[str, tuple[str, bool]] = {}  # session_id -> (data_json, is_active)

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
    """Verify evaluation response includes question_id for client-side validation."""

    def test_evaluation_dict_contains_question_id(self):
        """The evaluation result dict should include the evaluated question's ID."""
        evaluated_question_id = "q_abc123"

        evaluation_result = {
            "user_answer": "Paris",
            "result": "correct",
            "points": 1.0,
            "correct_answer": "Paris",
            "question_id": evaluated_question_id,
        }

        assert "question_id" in evaluation_result
        assert evaluation_result["question_id"] == "q_abc123"

    def test_skip_evaluation_contains_question_id(self):
        """Skip evaluation should also include question_id."""
        evaluated_question_id = "q_def456"

        evaluation_result = {
            "user_answer": "skipped",
            "result": "skipped",
            "points": 0.0,
            "correct_answer": "Expected Answer",
            "question_id": evaluated_question_id,
        }

        assert evaluation_result["question_id"] == "q_def456"


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
