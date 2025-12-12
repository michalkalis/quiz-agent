"""User feedback and rating service.

Integrates ChromaDB and SQL storage for ratings.
"""

from typing import Optional, List, Tuple
from datetime import datetime

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.database.sql_client import SQLClient
from quiz_shared.models.rating import QuestionRating


class FeedbackService:
    """Manages user ratings and feedback.

    Features:
    - Dual storage: ChromaDB (for retrieval) + SQL (for analytics)
    - Rating scale: 1-5 (1=bad, 5=excellent)
    - Automatic quality tracking
    - Low-rated question flagging
    """

    def __init__(
        self,
        chroma_client: ChromaDBClient,
        sql_client: SQLClient,
        low_rating_threshold: float = 2.5
    ):
        """Initialize feedback service.

        Args:
            chroma_client: ChromaDB client for question storage
            sql_client: SQL client for rating analytics
            low_rating_threshold: Threshold for flagging questions (default: 2.5)
        """
        self.chroma = chroma_client
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
            # Update ChromaDB user_ratings dict (for retrieval)
            chroma_success = self.chroma.update_rating(
                question_id=question_id,
                user_id=user_id,
                rating=rating
            )

            if not chroma_success:
                return False, "Question not found in database"

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
                print(f"Warning: SQL rating storage failed for {question_id}")

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

    def flag_poor_quality_questions(self) -> List[str]:
        """Flag questions that consistently receive low ratings.

        Returns:
            List of question IDs to review
        """
        low_rated = self.get_low_rated_questions()

        if low_rated:
            print(f"Found {len(low_rated)} low-rated questions (< {self.low_rating_threshold}):")
            for qid, rating in low_rated:
                print(f"  - {qid}: {rating:.2f} avg rating")

        return [qid for qid, _ in low_rated]
