"""The #156 backfill's write path against a real database.

Two properties matter beyond "rows appear":

- *Idempotency*: this importer is meant to be run again after a parser fix and
  again on prod after being proven locally. If a second run appended, the
  founder's average for a question would silently become the mean of duplicate
  copies of one opinion.
- *Raw scores survive*: a 1–5 round must keep its own bounds so the export can
  normalise. Rewriting a 5 into a 10 at import time would destroy the only
  record of what the founder actually wrote.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest_asyncio
from app.api.v1.ratings_store import normalize_to_10
from app.db.models.rating import Rating
from sqlalchemy import delete, func, select

from scripts import backfill_ratings as B
from scripts import backfill_ratings_parsers as P

TEST_ROUND = "test-round-156"
RATED_AT = datetime(2026, 7, 11, tzinfo=timezone.utc)


def _result() -> P.SourceResult:
    rows = [
        P.ParsedRating(
            round=TEST_ROUND, natural_key="A1", question_text="Question one?",
            rater="michal", score=4.5, scale_min=1, scale_max=5, rated_at=RATED_AT,
            reason="surprising", extra={"model": "model-a"},
        ),
        P.ParsedRating(
            round=TEST_ROUND, natural_key="A2", question_text="Question two?",
            rater="michal", score=2, scale_min=1, scale_max=5, rated_at=RATED_AT,
        ),
    ]
    return P.SourceResult(round=TEST_ROUND, rows=rows, seen=2)


@pytest_asyncio.fixture
async def clean_round(session):
    stmt = delete(Rating).where(Rating.source == f"backfill:{TEST_ROUND}")
    await session.execute(stmt)
    await session.commit()
    yield
    await session.execute(stmt)
    await session.commit()


async def _count(session) -> int:
    return (
        await session.execute(
            select(func.count()).select_from(Rating).where(
                Rating.source == f"backfill:{TEST_ROUND}"
            )
        )
    ).scalar_one()


class TestIdempotency:
    async def test_second_run_updates_the_same_rows(self, session, clean_round):
        first = await B.apply_source(session, _result(), execute=True)
        assert first == (2, 0)
        ids = set((await session.execute(
            select(Rating.id).where(Rating.source == f"backfill:{TEST_ROUND}")
        )).scalars())

        second = await B.apply_source(session, _result(), execute=True)
        assert second == (0, 2)
        assert await _count(session) == 2
        again = set((await session.execute(
            select(Rating.id).where(Rating.source == f"backfill:{TEST_ROUND}")
        )).scalars())
        assert again == ids

    async def test_dry_run_reports_the_same_counts_but_writes_nothing(
        self, session, clean_round
    ):
        assert await B.apply_source(session, _result(), execute=False) == (2, 0)
        assert await _count(session) == 0


class TestStoredShape:
    async def test_raw_score_and_scale_bounds_are_preserved(self, session, clean_round):
        await B.apply_source(session, _result(), execute=True)
        row = (await session.execute(
            select(Rating).where(Rating.dedupe_key == f"backfill:{TEST_ROUND}:A1:michal")
        )).scalar_one()
        assert (float(row.score), row.scale_min, row.scale_max) == (4.5, 1, 5)
        assert row.extra == {"model": "model-a"}
        assert row.rated_at.astimezone(timezone.utc) == RATED_AT

    async def test_export_normalises_the_1_to_5_round_onto_the_10_scale(
        self, session, clean_round
    ):
        await B.apply_source(session, _result(), execute=True)
        rows = (await session.execute(
            select(Rating).where(Rating.source == f"backfill:{TEST_ROUND}")
            .order_by(Rating.dedupe_key)
        )).scalars().all()
        normalized = [normalize_to_10(r.score, r.scale_min, r.scale_max) for r in rows]
        assert normalized == [8.875, 3.25]
        assert [float(r.score) for r in rows] == [4.5, 2.0]


class TestNormalizationMath:
    def test_the_1_to_5_endpoints_map_onto_the_1_to_10_endpoints(self):
        assert normalize_to_10(1, 1, 5) == 1.0
        assert normalize_to_10(3, 1, 5) == 5.5
        assert normalize_to_10(5, 1, 5) == 10.0

    def test_a_1_to_10_score_passes_through_unchanged(self):
        assert [normalize_to_10(v, 1, 10) for v in (1, 6, 10)] == [1.0, 6.0, 10.0]


class TestSourceCollection:
    def test_every_historical_round_is_wired_into_the_cli(self):
        rounds = [r.round for r in B.collect(P.REPO_ROOT, None)]
        assert rounds == [
            P.GOLD_ROUND, P.PILOT_ROUND, P.G3_ROUND, P.BASELINE_ROUND, P.PHASE_A_ROUND
        ]

    def test_the_lost_july_round_writes_no_rows(self):
        # Acceptance: grepping the export for this label must find nothing.
        assert "july-calibration" not in {r.round for r in B.collect(P.REPO_ROOT, None)}
        assert "RAW DATA LOST" in B.JULY_NOTE
