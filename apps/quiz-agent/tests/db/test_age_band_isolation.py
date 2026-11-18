"""#236 — questions written for a child age band stay out of the ordinary quiz.

The family section's questions live in the same shared library as everyone
else's, told apart only by `questions.age_band`. An adult who plays a normal
quiz or the daily challenge (on any build, including ones that will never know
the section exists) must never get a question worded for a four-year-old, and a
child's band must never be handed adult or other-band questions. A custom pack
is different: it is its own closed set, so a pack ordered for a child band
plays in full whatever its rows carry. All of it in real SQL, on the private
scratch database of the stock-count tests.
"""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest
from app.retrieval.question_retriever import QuestionRetriever
from app.shared_quiz import snapshot
from quiz_shared.database.pgvector_client import EMBEDDING_DIM
from quiz_shared.models.session import QuizSession
from sqlalchemy import text

from tests.db.test_question_stock_counts import NOW, _question, store  # noqa: F401

pytestmark = pytest.mark.asyncio

BANDS = ("kids_4_6", "kids_7_9", "kids_10_12")


def _stub_embedder(_text: str) -> list[float]:
    """The serve path embeds its query; a fixed vector keeps the test offline."""
    return [1.0] + [0.0] * (EMBEDDING_DIM - 1)


async def _library(store):  # noqa: F811
    """Two ordinary rows and two rows per band, all otherwise identical and
    servable, so the band is the ONLY thing that can tell them apart."""
    rows = {"ordinary": [_question(), _question()]}
    for band in BANDS:
        rows[band] = [_question(age_band=band), _question(age_band=band)]
    for group in rows.values():
        for q in group:
            assert await store.upsert(q) is True
    return {name: {q.id for q in group} for name, group in rows.items()}


async def _play_out(retriever: QuestionRetriever, session: QuizSession) -> list[str]:
    """Every question the session is served until the retriever runs dry."""
    served: list[str] = []
    for _ in range(50):
        question = await retriever.get_next_question(session)
        if question is None:
            return served
        served.append(question.id)
        session.asked_question_ids.append(question.id)
    raise AssertionError("retriever never ran dry")


@pytest.mark.parametrize("build_channel", [None, "testflight"])
async def test_ordinary_quiz_never_serves_a_band_question(store, build_channel):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    session = QuizSession(session_id="s", language="en", build_channel=build_channel)

    assert await retriever.count_available(session) == 2
    served = await _play_out(retriever, session)

    # Exactly the ordinary rows: none of a band, even after every fallback
    # (other difficulties, no difficulty) has been tried on an empty pool.
    assert sorted(served) == sorted(ids["ordinary"])


async def test_daily_challenge_never_draws_a_band_question(store):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store)

    drawn = {q.id for q in await retriever.daily_candidates("en")}

    assert drawn == ids["ordinary"]


@pytest.mark.parametrize("band", BANDS)
async def test_band_session_gets_exactly_its_band(store, band):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    session = QuizSession(session_id="s", language="en", age_band=band)

    served = await _play_out(retriever, session)

    # Neither ordinary questions nor another band's: a 4-6 child must not get
    # a 10-12 question any more than an adult one.
    assert sorted(served) == sorted(ids[band])


async def test_a_shared_link_never_carries_a_band_question(store):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store)
    every_id = [qid for group in ids.values() for qid in group]

    carried = await snapshot.corpus_ids(retriever, every_id, "en")

    assert set(carried) == ids["ordinary"]


async def test_public_fresh_page_never_shows_a_band_question(store):  # noqa: F811
    fresh = {
        "category": "entertainment",
        "boost_until": NOW + timedelta(days=10),
        "source_url": "https://example.org/a",
        "explanation": "Because.",
    }
    ordinary = _question(**fresh)
    banded = _question(age_band="kids_10_12", **fresh)
    for q in (ordinary, banded):
        assert await store.upsert(q) is True

    rows = await store.fresh_public_entertainment("en", 10)

    assert [r["id"] for r in rows] == [ordinary.id]


async def test_child_band_pack_plays_in_full_on_any_build(store):  # noqa: F811
    """A pack ordered for 7-9 (#236 task 236.1) stamps its band on every row.
    The pack is the paid, closed set the player chose: a session of a build
    that knows nothing about bands must still get every one of its questions,
    and only those (no ordinary or other-pack row slips in)."""
    pack_id = str(uuid.uuid4())
    pack_rows = [
        _question(pack_id=pack_id, age_band="kids_7_9", review_status="pending_review")
        for _ in range(3)
    ]
    others = [_question(), _question(pack_id=str(uuid.uuid4()), age_band="kids_7_9")]
    for q in pack_rows + others:
        assert await store.upsert(q) is True
    # Pack rows are persisted without an embedding (quiz-pack-api PersistStage).
    async with store._session_factory() as db:
        await db.execute(
            text("UPDATE questions SET embedding = NULL WHERE pack_id = :pid"),
            {"pid": uuid.UUID(pack_id)},
        )
        await db.commit()
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    session = QuizSession(session_id="s", language="en", pack_id=pack_id)

    served = await _play_out(retriever, session)

    assert sorted(served) == sorted(q.id for q in pack_rows)
    assert sorted(await retriever.pack_question_ids(pack_id)) == sorted(
        q.id for q in pack_rows
    )
