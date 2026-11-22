"""#242 — questions of the free rotating extra categories (`extra-*`) stay out of
every session that did not ask for that category.

Extra questions share the one library with the permanent corpus, told apart
only by the `extra-` category prefix. "All categories" is an empty filter, so
without a rule an extra question would reach the mixed quiz of every build
(old builds cannot even show the category), the daily challenge, shared links
and the availability count. The rule must also keep questions with NO category
(a classifier miss) playable, and must not block a player who picked the
category on purpose. Real SQL, on the scratch database of the stock-count tests.
"""

from __future__ import annotations

import pytest
from app.retrieval.question_retriever import QuestionRetriever
from app.shared_quiz import snapshot
from quiz_shared.database.pgvector_client import EMBEDDING_DIM
from quiz_shared.models.session import QuizSession

from tests.db.test_question_stock_counts import _question, store  # noqa: F401

pytestmark = pytest.mark.asyncio


def _stub_embedder(_text: str) -> list[float]:
    return [1.0] + [0.0] * (EMBEDDING_DIM - 1)


async def _library(store):  # noqa: F811
    """Permanent rows and rows of two extra categories, otherwise identical, so the category is the ONLY thing telling them apart."""
    rows = {
        "permanent": [_question("science"), _question("history")],
        "extra_x": [_question("extra-x"), _question("extra-x")],
        "extra_y": [_question("extra-y")],
    }
    for group in rows.values():
        for q in group:
            assert await store.upsert(q) is True
    return {name: {q.id for q in group} for name, group in rows.items()}


async def _play_out(retriever: QuestionRetriever, session: QuizSession) -> list[str]:
    served: list[str] = []
    for _ in range(50):
        question = await retriever.get_next_question(session)
        if question is None:
            return served
        served.append(question.id)
        session.asked_question_ids.append(question.id)
    raise AssertionError("retriever never ran dry")


@pytest.mark.parametrize("build_channel", [None, "testflight"])
async def test_mixed_quiz_never_serves_an_extra_question(store, build_channel):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    session = QuizSession(session_id="s", language="en", build_channel=build_channel)

    assert await retriever.count_available(session) == 2
    served = await _play_out(retriever, session)

    # Permanent rows only: no extra row may appear even after every fallback.
    assert sorted(served) == sorted(ids["permanent"])


async def test_explicit_extra_category_gets_its_questions(store):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    session = QuizSession(
        session_id="s", language="en", preferred_categories=["extra-x"]
    )

    assert await retriever.count_available(session) == 2
    served = await _play_out(retriever, session)

    # Only the chosen extra category: not the permanent corpus, not extra-y.
    assert sorted(served) == sorted(ids["extra_x"])


async def test_daily_challenge_never_draws_an_extra_question(store):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store)

    drawn = {q.id for q in await retriever.daily_candidates("en")}

    assert drawn == ids["permanent"]


async def test_a_shared_link_never_carries_an_extra_question(store):  # noqa: F811
    ids = await _library(store)
    retriever = QuestionRetriever(question_store=store)
    every_id = [qid for group in ids.values() for qid in group]

    carried = await snapshot.corpus_ids(retriever, every_id, "en")

    assert set(carried) == ids["permanent"]


async def test_prefix_is_matched_literally_not_as_a_pattern(store):  # noqa: F811
    """A category that merely resembles the prefix (`extraXfoo`) is ordinary:
    `_` / `%` must not act as LIKE wildcards and hide permanent questions."""
    look_alike = _question("extraXfoo")
    assert await store.upsert(look_alike) is True
    retriever = QuestionRetriever(question_store=store)

    drawn = {q.id for q in await retriever.daily_candidates("en")}

    assert drawn == {look_alike.id}


async def test_prefix_filter_keeps_null_categories():
    """The `questions.category` column is NOT NULL today, but a plain `$ne` /
    NOT LIKE would silently drop NULLs (NULL <> x is never true) the day a row
    has none. The clause must say IS NULL explicitly."""
    from quiz_shared.database.pgvector_client import _build_where

    (clause,) = _build_where({"category": {"$not_prefix_or_null": "extra-"}})

    sql = str(clause.compile(compile_kwargs={"literal_binds": True}))
    assert "category IS NULL" in sql and "questions.category NOT LIKE" in sql
