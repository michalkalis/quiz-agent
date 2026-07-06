"""User feedback and rating service.

Ratings persist in the SQL ratings store only (#41 D1) — the old embedded
`user_ratings`/`usage_count`/`review_status` writes to the question store
had zero readers and were dropped with the ChromaDB decommission.
"""

import logging
from typing import Optional, List, Tuple
from datetime import datetime

logger = logging.getLogger(__name__)

from quiz_shared.database.sql_client import SQLClient
from quiz_shared.models.rating import QuestionRating


class FeedbackService:
    """Manages user ratings and feedback.

    Features:
    - SQL storage for rating analytics
    - Rating scale: 1-5 (1=bad, 5=excellent)
    - Automatic quality tracking
    - Low-rated question flagging
    """

    def __init__(
        self,
        sql_client: SQLClient,
        low_rating_threshold: float = 2.5,
    ):
        """Initialize feedback service.

        Args:
            sql_client: SQL client for rating analytics
            low_rating_threshold: Threshold for flagging questions (default: 2.5)
        """
        self.sql = sql_client
        self.low_rating_threshold = low_rating_threshold

    async def submit_rating(
        self,
        question_id: str,
        user_id: str,
        rating: int,
        feedback_text: Optional[str] = None,
        session_id: Optional[str] = None,
    ) -> Tuple[bool, str]:
        """Submit a rating for a question.

        Args:
            question_id: Question ID
            user_id: User ID
            rating: Rating 1-5 (1=bad, 5=excellent)
            feedback_text: Optional text feedback
            session_id: Quiz session the rating came from (analytics context)

        Returns:
            Tuple of (success, message)

        Example:
            >>> service = FeedbackService(sql)
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
            rating_obj = QuestionRating(
                question_id=question_id,
                session_id=session_id,
                user_id=user_id,
                rating=rating,
                feedback=feedback_text,
                created_at=datetime.now(),
            )

            if not self.sql.add_rating(rating_obj):
                return False, "Failed to persist rating"

            return True, "Rating submitted successfully"

        except Exception as e:
            return False, f"Failed to submit rating: {str(e)}"

    def get_question_ratings(self, question_id: str) -> List[QuestionRating]:
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
        self, threshold: Optional[float] = None
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

        Logs the flag for operator follow-up. The old `review_status`
        write-back to the question store had no reader (#41 D1) and was
        dropped; the flag is acknowledged, not persisted per-question.
        """
        logger.info("Question %s flagged by %s: %s", question_id, user_id, reason)
        return True, "Question flagged for review"

    def flag_poor_quality_questions(self) -> List[str]:
        """Flag questions that consistently receive low ratings.

        Returns:
            List of question IDs to review
        """
        low_rated = self.get_low_rated_questions()

        if low_rated:
            logger.info(
                "Found %d low-rated questions (< %.1f)",
                len(low_rated),
                self.low_rating_threshold,
            )
            for qid, rating in low_rated:
                logger.info("  %s: %.2f avg rating", qid, rating)

        return [qid for qid, _ in low_rated]
