"""User feedback and rating service.

Integrates ChromaDB and SQL storage for ratings.
"""

import logging
from typing import Optional, List, Tuple
from datetime import datetime

logger = logging.getLogger(__name__)

from quiz_shared.database.question_store import QuestionStore
from quiz_shared.database.sql_client import SQLClient
from quiz_shared.models.rating import QuestionRating


class FeedbackService:
    """Manages user ratings and feedback.

    Features:
    - Dual storage: QuestionStore (for retrieval) + SQL (for analytics)
    - Rating scale: 1-5 (1=bad, 5=excellent)
    - Automatic quality tracking
    - Low-rated question flagging
    """

    def __init__(
        self,
        question_store: QuestionStore,
        sql_client: SQLClient,
        low_rating_threshold: float = 2.5
    ):
        """Initialize feedback service.

        Args:
            question_store: QuestionStore for question read/write
            sql_client: SQL client for rating analytics
            low_rating_threshold: Threshold for flagging questions (default: 2.5)
        """
        self.store = question_store
        self.sql = sql_client
        self.low_rating_threshold = low_rating_threshold

    async def submit_rating(
        self,
        question_id: str,
        user_id: str,
        rating: int,
        feedback_text: Optional[str] = None
    ) -> Tuple[bool, str]:
        """Submit a rating for a question.

        Args:
            question_id: Question ID
            user_id: User ID
            rating: Rating 1-5 (1=bad, 5=excellent)
            feedback_text: Optional text feedback

        Returns:
            Tuple of (success, message)

        Example:
            >>> service = FeedbackService(chroma, sql)
            >>> success, msg = await service.submit_rating(
            ...     "q_abc123",
            ...     "user_1",
            ...     5,
            ...     "Great question!"
            ... )
        """
        # Validate rating
        if not 1 <= rating <= 5:
            return False, "Rating must be between 1 and 5"

        try:
            # Update embedded user_ratings dict on the question (for retrieval)
            question = self.store.get(question_id)
            if not question:
                return False, "Question not found in database"
            question.user_ratings[user_id] = rating
            question.usage_count += 1
            if not self.store.upsert(question):
                return False, "Failed to persist rating"

            # Store detailed rating in SQL (for analytics)
            rating_obj = QuestionRating(
                question_id=question_id,
                user_id=user_id,
                rating=rating,
                feedback_text=feedback_text,
                created_at=datetime.now()
            )

            sql_success = self.sql.add_rating(rating_obj)

            if not sql_success:
                # ChromaDB updated but SQL failed - log warning
                logger.warning("SQL rating storage failed for %s", question_id)

            return True, "Rating submitted successfully"

        except Exception as e:
            return False, f"Failed to submit rating: {str(e)}"

    def get_question_ratings(
        self,
        question_id: str
    ) -> List[QuestionRating]:
        """Get all ratings for a question.

        Args:
            question_id: Question ID

        Returns:
            List of QuestionRating objects
        """
        return self.sql.get_ratings_by_question(question_id)

    def get_average_rating(self, question_id: str) -> Optional[float]:
        """Get average rating for a question.

        Args:
            question_id: Question ID

        Returns:
            Average rating or None if no ratings
        """
        return self.sql.get_avg_rating(question_id)

    def get_low_rated_questions(
        self,
        threshold: Optional[float] = None
    ) -> List[Tuple[str, float]]:
        """Get questions with low average ratings.

        Args:
            threshold: Rating threshold (default: use service threshold)

        Returns:
            List of (question_id, avg_rating) tuples

        Example:
            >>> low_rated = service.get_low_rated_questions()
            >>> for qid, rating in low_rated:
            ...     print(f"Question {qid}: {rating:.2f} avg")
        """
        threshold = threshold or self.low_rating_threshold
        return self.sql.get_low_rated_questions(threshold)

    async def flag_question(
        self,
        question_id: str,
        user_id: str,
        reason: Optional[str] = None,
    ) -> Tuple[bool, str]:
        """Flag a question as potentially incorrect.

        Sets review_status to 'needs_revision' and stores the flag reason.
        """
        try:
            question = self.store.get(question_id)
            if not question:
                return False, "Question not found in database"
            question.review_status = "needs_revision"
            question.review_notes = f"Flagged by {user_id}: {reason or 'No reason given'}"
            if not self.store.upsert(question):
                return False, "Failed to persist flag"

            logger.info("Question %s flagged by %s: %s", question_id, user_id, reason)
            return True, "Question flagged for review"
        except Exception as e:
            return False, f"Failed to flag question: {str(e)}"

    def flag_poor_quality_questions(self) -> List[str]:
        """Flag questions that consistently receive low ratings.

        Returns:
            List of question IDs to review
        """
        low_rated = self.get_low_rated_questions()

        if low_rated:
            logger.info("Found %d low-rated questions (< %.1f)", len(low_rated), self.low_rating_threshold)
            for qid, rating in low_rated:
                logger.info("  %s: %.2f avg rating", qid, rating)

        return [qid for qid, _ in low_rated]
