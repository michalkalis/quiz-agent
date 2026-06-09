"""Tests for _build_metadata_filters in QuestionRetriever.

49.1: Verifies text_multichoice is included in the type filter.
49.2: Verifies question_to_dict passes MCQ fields intact for iOS.
"""

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

from app.retrieval.question_retriever import QuestionRetriever
from app.serializers import question_to_dict


def _make_session(**kwargs) -> QuizSession:
    defaults = {
        "session_id": "test-session",
        "current_difficulty": "medium",
        "language": "en",
    }
    defaults.update(kwargs)
    return QuizSession(**defaults)


def _make_retriever() -> QuestionRetriever:
    """Build a QuestionRetriever without a real store — only _build_metadata_filters is called."""
    return QuestionRetriever.__new__(QuestionRetriever)


class TestBuildMetadataFilters:
    def test_text_multichoice_in_type_filter(self):
        """Launch decision: MCQ ships at launch.

        The retriever's type filter is the only gate between approved
        text_multichoice questions in pgvector and a live session. Removing
        text_multichoice from this list silently disables MCQ end-to-end even
        if generation and content-approval pipelines are fully functional.
        """
        retriever = _make_retriever()
        session = _make_session()

        filters = retriever._build_metadata_filters("medium", session)

        assert set(filters["type"]["$in"]) == {"text", "image", "text_multichoice"}

    def test_review_status_approved_enforced(self):
        """Only human-approved questions may reach a session."""
        retriever = _make_retriever()
        session = _make_session()

        filters = retriever._build_metadata_filters("medium", session)

        assert filters["review_status"] == "approved"

    def test_non_english_adds_language_filter(self):
        retriever = _make_retriever()
        session = _make_session(language="sk")

        filters = retriever._build_metadata_filters("medium", session)

        assert filters["language_dependent"] is False

    def test_english_session_no_language_filter(self):
        retriever = _make_retriever()
        session = _make_session(language="en")

        filters = retriever._build_metadata_filters("medium", session)

        assert "language_dependent" not in filters

    def test_preferred_categories_applied(self):
        retriever = _make_retriever()
        session = _make_session(preferred_categories=["music", "movies"])

        filters = retriever._build_metadata_filters("medium", session)

        assert filters["category"] == {"$in": ["music", "movies"]}

    def test_no_category_filter_when_unset(self):
        retriever = _make_retriever()
        session = _make_session()

        filters = retriever._build_metadata_filters("medium", session)

        assert "category" not in filters


class TestSerializerMCQContract:
    def test_mcq_type_and_possible_answers_survive_serialization(self):
        """iOS selects MCQOptionPicker on `type` and renders `possible_answers`.

        A serializer that drops either field turns an MCQ into a broken
        free-form question — same bug class as the generated_by/headline_answer
        serializer bugs fixed in 16161de.
        """
        options = {"a": "Paris", "b": "London", "c": "Berlin", "d": "Madrid"}
        question = Question(
            id="q_test_mcq_01",
            question="What is the capital of France?",
            answer="Paris",
            correct_answer="a",
            type="text_multichoice",
            possible_answers=options,
            difficulty="easy",
            topic="geography",
            category="general",
        )

        result = question_to_dict(question)

        assert result["type"] == "text_multichoice"
        assert result["possible_answers"] == options
        assert "correct_answer" not in result
