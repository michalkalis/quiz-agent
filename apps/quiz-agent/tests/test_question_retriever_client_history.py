"""Cross-session history must hold for EVERY question, not just the first.

The iOS client sends its full seen-question history as excluded_question_ids
on /start only. voice.py's mid-quiz retrieval calls
``get_next_question(session)`` with no client history of its own, so the
history must live on the session (``QuizSession.client_excluded_ids``, set by
routes.start_quiz) and be merged into the exclusion set on every retrieval.
Regression: before this, questions from previous quizzes could repeat from
question 2 onward (field report 2026-07-29).
"""

from unittest.mock import MagicMock

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

from app.retrieval.question_retriever import QuestionRetriever


def _make_question(qid: str) -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        type="text",
        correct_answer="answer",
        topic="Entertainment",
        category="general",
        difficulty="medium",
        review_status="approved",
    )


def _retriever() -> QuestionRetriever:
    store = MagicMock()
    store.search.return_value = [_make_question("q_fresh")]
    retriever = QuestionRetriever(question_store=store)
    # Bypass diversity scoring (needs real embeddings); exclusion under test
    # happens earlier, in the store.search call.
    retriever._select_with_semantic_diversity = MagicMock(
        side_effect=lambda candidates, session: candidates[0]
    )
    return retriever


def _excluded_ids_passed_to_store(retriever: QuestionRetriever) -> set:
    return set(retriever._store.search.call_args.kwargs["excluded_ids"])


def test_session_client_history_is_excluded_without_explicit_param():
    """voice.py's call shape: no client_excluded_ids argument. The history
    persisted on the session by /start must still reach the store's exclusion
    set — otherwise every question after the first can repeat prior quizzes."""
    session = QuizSession(
        session_id="sess_hist", current_difficulty="medium", language="en"
    )
    session.client_excluded_ids = ["q_seen_last_week", "q_seen_yesterday"]
    session.asked_question_ids = ["q_asked_now"]
    retriever = _retriever()

    result = retriever.get_next_question(session)

    assert result is not None
    excluded = _excluded_ids_passed_to_store(retriever)
    assert {"q_seen_last_week", "q_seen_yesterday", "q_asked_now"} <= excluded


def test_explicit_param_and_session_history_are_merged():
    """/start's call shape passes the history explicitly; both sources must
    merge rather than one shadowing the other."""
    session = QuizSession(
        session_id="sess_hist2", current_difficulty="medium", language="en"
    )
    session.client_excluded_ids = ["q_on_session"]
    retriever = _retriever()

    result = retriever.get_next_question(
        session, client_excluded_ids=["q_from_request"]
    )

    assert result is not None
    excluded = _excluded_ids_passed_to_store(retriever)
    assert {"q_on_session", "q_from_request"} <= excluded
