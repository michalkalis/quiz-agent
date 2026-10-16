"""Question ratings in Postgres (#207.20; was ``ratings.db`` on the volume)."""

from __future__ import annotations

import logging

from quiz_shared.models.rating import QuestionRating
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import QuestionRatingRow

logger = logging.getLogger(__name__)


class PostgresRatingStore:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sessionmaker

    async def add_rating(self, rating: QuestionRating) -> bool:
        try:
            async with self._sm() as db:
                db.add(
                    QuestionRatingRow(
                        id=rating.id,
                        question_id=rating.question_id,
                        session_id=rating.session_id,
                        user_id=rating.user_id,
                        rating=rating.rating,
                        feedback=rating.feedback,
                        was_correct=rating.was_correct,
                        user_answer=rating.user_answer,
                        difficulty_at_time=rating.difficulty_at_time,
                        created_at=rating.created_at,
                    )
                )
                await db.commit()
            return True
        except Exception as e:  # noqa: BLE001 — the route answers 500 on False
            logger.error("Error adding rating: %s", e)
            return False


class MemoryRatingStore:
    """DB-less dev stand-in."""

    def __init__(self) -> None:
        self.ratings: list[QuestionRating] = []

    async def add_rating(self, rating: QuestionRating) -> bool:
        self.ratings.append(rating)
        return True
