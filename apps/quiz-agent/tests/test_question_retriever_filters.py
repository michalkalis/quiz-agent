"""Metadata-filter construction for QuestionRetriever.

Intent: MCQ questions must be retrievable by the voice quiz. MCQ is in the
first App Store launch batch (launch decision #3, 2026-06-08), so the
retriever's type filter has to admit ``text_multichoice`` — not just plain
``text``/``image``. If this filter ever drops ``text_multichoice`` again, MCQ
questions silently vanish from selection even though they're approved, so this
test guards the launch-critical contract rather than the literal list.
"""

from unittest.mock import MagicMock

from quiz_shared.models.session import QuizSession

from app.retrieval.question_retriever import QuestionRetriever


def _retriever() -> QuestionRetriever:
    # Pass a truthy store so __init__ skips _build_default_store() (which would
    # try to open a real pgvector connection).
    return QuestionRetriever(question_store=MagicMock())


def test_metadata_filter_admits_text_multichoice():
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_test", current_difficulty="medium", language="en"
    )

    filters = retriever._build_metadata_filters("medium", session)

    allowed = filters["type"]["$in"]
    assert "text_multichoice" in allowed, (
        "MCQ questions must be selectable — text_multichoice dropped from the "
        "retriever type filter would silently exclude approved MCQ questions "
        "(launch decision #3)"
    )
    # The original plain-text path must keep working alongside MCQ.
    assert "text" in allowed


def test_metadata_filter_still_restricts_to_approved():
    # Guard against a regression where widening the type filter accidentally
    # relaxes the human-review gate.
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_test", current_difficulty="medium", language="en"
    )

    filters = retriever._build_metadata_filters("medium", session)

    assert filters["review_status"] == "approved"
