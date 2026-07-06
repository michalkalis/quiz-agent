"""FeedbackService — SQL-only persistence (#41 A4/A6, decision D1).

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


class FakeSQLClient:
    """Records ratings in memory; can simulate a write failure."""

    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.ratings: List[QuestionRating] = []

    def add_rating(self, rating: QuestionRating) -> bool:
        if self.fail:
            return False
        self.ratings.append(rating)
        return True


@pytest.mark.asyncio
async def test_submit_rating_persists_to_sql_only() -> None:
    """The SQL record is the single durable trace of a rating after D1 —
    it must carry the full detail (who, what, score, text)."""
    sql = FakeSQLClient()
    service = FeedbackService(sql_client=sql)

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
    service = FeedbackService(sql_client=FakeSQLClient(fail=True))
    ok, msg = await service.submit_rating("q-1", "user-1", 4)
    assert ok is False
    assert "persist" in msg.lower()


@pytest.mark.asyncio
@pytest.mark.parametrize("rating", [0, 6, -1])
async def test_submit_rating_rejects_out_of_range(rating: int) -> None:
    """Invalid ratings must be rejected before any write — garbage in the
    analytics store would skew the low-rated-question flagging."""
    sql = FakeSQLClient()
    service = FeedbackService(sql_client=sql)
    ok, _ = await service.submit_rating("q-1", "user-1", rating)
    assert ok is False
    assert sql.ratings == []


@pytest.mark.asyncio
async def test_flag_question_succeeds_without_any_store_write() -> None:
    """Flagging is acknowledge-and-log after D1 (the old review_status
    write-back had zero readers) — /flag must still return success so the
    voice UX confirms the flag to the driver."""
    sql = FakeSQLClient()
    service = FeedbackService(sql_client=sql)
    ok, msg = await service.flag_question("q-1", "user-1", "wrong answer")
    assert ok is True
    assert sql.ratings == []  # no rating record, no store write


@pytest.mark.asyncio
async def test_rating_roundtrips_through_real_sqlite(tmp_path) -> None:
    """End-to-end through the real SQLClient: the pre-#41 schema made every
    rating insert fail silently (NOT NULL context columns + required model
    fields the endpoint can't supply), so 'ratings persist in SQLite' was a
    lie. This locks in that a /rate-shaped call actually lands a row that can
    be read back for analytics."""
    from quiz_shared.database.sql_client import SQLClient

    sql = SQLClient(database_url=f"sqlite:///{tmp_path}/ratings.db")
    service = FeedbackService(sql_client=sql)

    ok, _ = await service.submit_rating(
        "q-42", "user-1", 2, "confusing", session_id="sess-9"
    )
    assert ok is True

    stored = sql.get_ratings_by_question("q-42")
    assert len(stored) == 1
    assert stored[0].rating == 2
    assert stored[0].feedback == "confusing"
    assert sql.get_avg_rating("q-42") == 2.0


@pytest.mark.asyncio
async def test_legacy_ratings_table_is_rebuilt_when_empty(tmp_path) -> None:
    """Existing deployments carry the legacy NOT NULL table (always empty —
    inserts never succeeded). SQLClient must rebuild it on init, or the fixed
    write path would keep failing against the old schema."""
    import sqlite3

    from quiz_shared.database.sql_client import SQLClient

    db = tmp_path / "ratings.db"
    con = sqlite3.connect(db)
    con.execute(
        """CREATE TABLE question_ratings (
            id VARCHAR NOT NULL, question_id VARCHAR NOT NULL,
            session_id VARCHAR NOT NULL, user_id VARCHAR,
            rating INTEGER NOT NULL, feedback TEXT,
            was_correct BOOLEAN NOT NULL, user_answer VARCHAR NOT NULL,
            difficulty_at_time VARCHAR NOT NULL, created_at DATETIME,
            PRIMARY KEY (id))"""
    )
    con.commit()
    con.close()

    sql = SQLClient(database_url=f"sqlite:///{db}")
    service = FeedbackService(sql_client=sql)
    ok, _ = await service.submit_rating("q-1", "user-1", 4, session_id="sess-1")
    assert ok is True
    assert len(sql.get_ratings_by_question("q-1")) == 1


def test_service_takes_no_question_store() -> None:
    """Structural lock-in for D1: the service signature has no question_store
    param — reintroducing a store write would have to consciously widen it."""
    params = inspect.signature(FeedbackService.__init__).parameters
    assert "question_store" not in params
