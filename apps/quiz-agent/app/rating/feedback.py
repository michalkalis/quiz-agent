"""User feedback and rating service.

Ratings persist in the ratings store only (#41 D1; Postgres since #207.20,
``app.rating.store``) — the old embedded
`user_ratings`/`usage_count`/`review_status` writes to the question store
had zero readers and were dropped with the ChromaDB decommission.
"""

import logging
from typing import Optional, Protocol, Tuple
from datetime import datetime, timezone

from quiz_shared.models.rating import QuestionRating

logger = logging.getLogger(__name__)


class RatingStore(Protocol):
    async def add_rating(self, rating: QuestionRating) -> bool: ...


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
        rating_store: RatingStore,
        low_rating_threshold: float = 2.5,
    ):
        """Initialize feedback service.

        Args:
            rating_store: durable rating store (``app.rating.store``)
            low_rating_threshold: Threshold for flagging questions (default: 2.5)
        """
        self.store = rating_store
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
                created_at=datetime.now(timezone.utc),
            )

            if not await self.store.add_rating(rating_obj):
                return False, "Failed to persist rating"

            return True, "Rating submitted successfully"

        except Exception as e:
            return False, f"Failed to submit rating: {str(e)}"

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
