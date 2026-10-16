"""FeedbackService — rating-store-only persistence (#41 A4/A6, decision D1).

Why these tests matter: #41 D1 drops the ChromaDB write-back
(`user_ratings`/`usage_count` on rate, `review_status` on flag) because
nothing ever read those fields. The contract after the cutover:

- a rating persists as a detailed record in the SQL ratings store — the ONLY
  durable rating storage left; if that write fails, the endpoint must say so
  instead of pretending success,
- neither /rate nor /flag touches a question store at all — the service no
  longer takes one, which these tests lock in structurally.
"""

from __future__ import annotations

from typing import List

import inspect

import pytest

from app.rating.feedback import FeedbackService
from quiz_shared.models.rating import QuestionRating


class FakeRatingStore:
    """Records ratings in memory; can simulate a write failure."""

    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.ratings: List[QuestionRating] = []

    async def add_rating(self, rating: QuestionRating) -> bool:
        if self.fail:
            return False
        self.ratings.append(rating)
        return True


@pytest.mark.asyncio
async def test_submit_rating_persists_to_sql_only() -> None:
    """The SQL record is the single durable trace of a rating after D1 —
    it must carry the full detail (who, what, score, text)."""
    sql = FakeRatingStore()
    service = FeedbackService(rating_store=sql)

    ok, msg = await service.submit_rating(
        "q-1", "user-1", 5, "Great question!", session_id="sess-1"
    )

    assert ok is True
    assert len(sql.ratings) == 1
    stored = sql.ratings[0]
    assert stored.question_id == "q-1"
    assert stored.session_id == "sess-1"
    assert stored.user_id == "user-1"
    assert stored.rating == 5
    assert stored.feedback == "Great question!"
    assert stored.id  # generated — the API caller never supplies one


@pytest.mark.asyncio
async def test_submit_rating_fails_loud_when_sql_write_fails() -> None:
    """With Chroma gone there is no second store to fall back on — a failed
    SQL write means the rating is lost and the API must return an error."""
    service = FeedbackService(rating_store=FakeRatingStore(fail=True))
    ok, msg = await service.submit_rating("q-1", "user-1", 4)
    assert ok is False
    assert "persist" in msg.lower()


@pytest.mark.asyncio
@pytest.mark.parametrize("rating", [0, 6, -1])
async def test_submit_rating_rejects_out_of_range(rating: int) -> None:
    """Invalid ratings must be rejected before any write — garbage in the
    analytics store would skew the low-rated-question flagging."""
    sql = FakeRatingStore()
    service = FeedbackService(rating_store=sql)
    ok, _ = await service.submit_rating("q-1", "user-1", rating)
    assert ok is False
    assert sql.ratings == []


@pytest.mark.asyncio
async def test_flag_question_succeeds_without_any_store_write() -> None:
    """Flagging is acknowledge-and-log after D1 (the old review_status
    write-back had zero readers) — /flag must still return success so the
    voice UX confirms the flag to the driver."""
    sql = FakeRatingStore()
    service = FeedbackService(rating_store=sql)
    ok, msg = await service.flag_question("q-1", "user-1", "wrong answer")
    assert ok is True
    assert sql.ratings == []  # no rating record, no store write


@pytest.mark.asyncio
async def test_rating_roundtrips_through_postgres(db_sessionmaker) -> None:
    """End-to-end through the real Postgres store: a /rate-shaped call (no
    answer/difficulty context the endpoint can't supply) must actually land a
    row that can be read back for analytics, not fail on NOT NULL columns."""
    from sqlalchemy import select

    from app.db.models import QuestionRatingRow
    from app.rating.store import PostgresRatingStore

    service = FeedbackService(rating_store=PostgresRatingStore(db_sessionmaker))

    ok, _ = await service.submit_rating(
        "q-42", "user-1", 2, "confusing", session_id="sess-9"
    )
    assert ok is True

    async with db_sessionmaker() as db:
        rows = (
            (
                await db.execute(
                    select(QuestionRatingRow).where(
                        QuestionRatingRow.question_id == "q-42"
                    )
                )
            )
            .scalars()
            .all()
        )
    assert len(rows) == 1
    assert rows[0].rating == 2
    assert rows[0].feedback == "confusing"
    assert rows[0].session_id == "sess-9"
    assert rows[0].user_id == "user-1"


def test_service_takes_no_question_store() -> None:
    """Structural lock-in for D1: the service signature has no question_store
    param — reintroducing a store write would have to consciously widen it."""
    params = inspect.signature(FeedbackService.__init__).parameters
    assert "question_store" not in params
