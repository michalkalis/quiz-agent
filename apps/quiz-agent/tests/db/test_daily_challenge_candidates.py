"""#205 205.1 — which rows a daily challenge may draw from, in real SQL.

The set is the same for every player of a language, so it may only use rows
every one of them is served the same way: approved (never TestFlight-only
pending rows), no images, no custom-pack rows, and in sk/cs no English row
without a stored translation (a serve-time translation words it differently
per player). Reuses the private scratch database of the stock-count tests.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.retrieval.question_retriever import QuestionRetriever

from tests.db.test_question_stock_counts import _question, store  # noqa: F401

pytestmark = pytest.mark.asyncio


async def test_only_rows_every_player_is_served_alike(store):  # noqa: F811
    rows = {
        "en_text": _question(category="history"),
        "en_mcq": _question(
            type="text_multichoice",
            possible_answers={"a": "1", "b": "42"},
            correct_answer="b",
        ),
        "pending": _question(review_status="pending_review"),
        "image": _question(type="image"),
        "pack": _question(pack_id=str(uuid.uuid4())),
        "sk_native": _question(language="sk"),
    }
    for q in rows.values():
        assert await store.upsert(q) is True
    retriever = QuestionRetriever(question_store=store)

    en = {q.id for q in await retriever.daily_candidates("en")}
    names = {v.id: k for k, v in rows.items()}
    assert sorted(names[i] for i in en) == ["en_mcq", "en_text"]

    sk = {q.id for q in await retriever.daily_candidates("sk")}
    # English rows have no stored Slovak translation here → only the native row.
    assert sk == {rows["sk_native"].id}


async def test_timely_rows_reach_the_candidates_however_small_the_sample(store):  # noqa: F811
    """Why: the day's timely place can only be filled if the handful of
    currently boosted rows is among the candidates; a random sample of a big
    corpus would miss them. A permanent boost is not a current topic."""
    for _ in range(6):
        assert await store.upsert(_question(category="history")) is True
    hot = _question(boost_until=datetime.now(UTC) + timedelta(days=7))
    ended = _question(boost_until=datetime.now(UTC) - timedelta(days=1))
    forever = _question(boost_until=datetime(9999, 1, 1, tzinfo=UTC))
    for q in (hot, ended, forever):
        assert await store.upsert(q) is True
    retriever = QuestionRetriever(question_store=store)

    for _ in range(5):
        drawn = [q.id for q in await retriever.daily_candidates("en", n=1)]
        assert hot.id in drawn
        assert len(drawn) == len(set(drawn)) <= 2
