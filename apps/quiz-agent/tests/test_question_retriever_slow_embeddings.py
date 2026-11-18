"""A slow embeddings API must not hold the next question (#235).

Why this matters to a player: each next-question lookup embeds its query text
to rank candidates by similarity. With the shared client's 30 s timeout and 2
retries, a slow (not down) embeddings API kept the player waiting 90 s or more
for the next question, long after the app had given up. The lookup now makes
one attempt of at most ``QUERY_EMBED_TIMEOUT_S`` and then picks the question
without ranking, through the store's unranked sample under the same filters.

The limit is shrunk to milliseconds and the slow API simply never answers, so
the tests prove the bound without sleeping for it. The filter guarantees of the
unranked pick are proven in real SQL in
``tests/db/test_unranked_pick_filters.py``.
"""

from __future__ import annotations

import asyncio
import logging

import pytest
from app.retrieval import question_retriever as retriever_module
from app.retrieval.question_retriever import (
    QueryEmbeddingUnavailable,
    QuestionRetriever,
    embed_query,
)
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

GUARD_S = 1.0  # a broken bound fails the test instead of hanging it


def _question(qid: str, **overrides) -> Question:
    fields = {
        "id": qid,
        "question": f"Question {qid}?",
        "type": "text",
        "correct_answer": "answer",
        "topic": "history",
        "category": "history",
        "difficulty": "medium",
        "language": "en",
        "review_status": "approved",
        "embedding": [1.0, 0.0],
    }
    fields.update(overrides)
    return Question(**fields)


class _Store:
    """Embeds query text through the injected embedder, like the real store."""

    def __init__(self, rows: list[Question], embedder=embed_query):
        self._rows = {q.id: q for q in rows}
        self._embedder = embedder
        self.searches: list[str | None] = []
        self.samples: list[dict] = []

    def _match(self, filters, excluded_ids):
        excluded = set(excluded_ids or [])
        return [
            q
            for q in self._rows.values()
            if q.id not in excluded
            and ("pack_id" not in filters or q.pack_id == filters["pack_id"])
        ]

    async def search(
        self, query_text=None, filters=None, n_results=10, excluded_ids=None
    ):
        self.searches.append(query_text)
        if query_text:
            await self._embedder(query_text)
        return self._match(filters or {}, excluded_ids)[:n_results]

    async def sample(self, filters=None, n_results=100, excluded_ids=None):
        self.samples.append(dict(filters or {}))
        return self._match(filters or {}, excluded_ids)[:n_results]

    async def get(self, question_id):
        return self._rows.get(question_id)

    async def count(self, filters=None):
        return len(self._rows)


class _EmbeddingsApi:
    """Stands in for ``generate_embedding_async``; records each attempt."""

    def __init__(self, behaviour: str):
        self.behaviour = behaviour
        self.calls: list[dict] = []

    async def __call__(self, text, **kwargs):
        self.calls.append(kwargs)
        if self.behaviour == "slow":
            await asyncio.Event().wait()
        if self.behaviour == "error":
            raise RuntimeError("503 upstream overloaded")
        return [1.0, 0.0]


@pytest.fixture
def api(monkeypatch):
    def install(behaviour: str) -> _EmbeddingsApi:
        fake = _EmbeddingsApi(behaviour)
        monkeypatch.setattr(retriever_module, "generate_embedding_async", fake)
        return fake

    monkeypatch.setattr(retriever_module, "QUERY_EMBED_TIMEOUT_S", 0.01)
    return install


async def test_slow_embedding_gives_up_after_one_short_attempt(api):
    slow = api("slow")

    with pytest.raises(QueryEmbeddingUnavailable, match="no embedding within"):
        await asyncio.wait_for(embed_query("history question"), GUARD_S)

    # One attempt, and the SDK's own retries are switched off for it.
    assert slow.calls == [
        {"model": retriever_module.QUERY_EMBED_MODEL, "max_retries": 0}
    ]


async def test_failed_embedding_is_not_retried_on_the_hot_path(api):
    failing = api("error")

    with pytest.raises(QueryEmbeddingUnavailable, match="503"):
        await embed_query("history question")
    assert len(failing.calls) == 1


async def test_slow_embeddings_still_serve_the_next_question_in_time(api, caplog):
    api("slow")
    store = _Store([_question("q1"), _question("q2")])
    session = QuizSession(session_id="s", language="en", asked_question_ids=["q1"])

    with caplog.at_level(logging.WARNING, logger="app.retrieval.question_retriever"):
        question = await asyncio.wait_for(
            QuestionRetriever(question_store=store).get_next_question(session),
            GUARD_S,
        )

    assert question is not None and question.id == "q2"  # never a repeat
    # One bounded wait per lookup: the ranked fallback chain is skipped, it
    # would only wait for the same slow API again.
    assert len(store.searches) == 1
    assert store.samples, "the unranked pick must come from the store's sample"
    assert "without similarity ranking" in caplog.text


async def test_fast_embeddings_keep_the_ranked_pick(api, caplog):
    api("fast")
    store = _Store([_question("q1")])
    session = QuizSession(session_id="s", language="en")

    with caplog.at_level(logging.WARNING, logger="app.retrieval.question_retriever"):
        question = await QuestionRetriever(question_store=store).get_next_question(
            session
        )

    assert question is not None and question.id == "q1"
    assert store.samples == []
    assert "without similarity ranking" not in caplog.text


async def test_unranked_pick_relaxes_only_difficulty_and_skips_unembedded_rows(api):
    """Same last resort as the ranked chain (drop difficulty, keep the rest);
    a row without a stored embedding is one a ranked search could not return,
    and the diversity pick would embed it on the spot."""
    api("slow")
    store = _Store(
        [_question("no-vector", embedding=None), _question("other-difficulty")]
    )
    store.sample = _sample_by_difficulty(store, available="hard")
    session = QuizSession(session_id="s", language="en", current_difficulty="easy")

    question = await asyncio.wait_for(
        QuestionRetriever(question_store=store).get_next_question(session), GUARD_S
    )

    assert question is not None and question.id == "other-difficulty"
    assert [f.get("difficulty") for f in store.samples] == ["easy", None]
    assert all(f["review_status"] == "approved" for f in store.samples)


def _sample_by_difficulty(store: _Store, available: str):
    async def sample(filters=None, n_results=100, excluded_ids=None):
        store.samples.append(dict(filters))
        if filters.get("difficulty") not in (None, available):
            return []
        return [q for q in store._rows.values()][:n_results]

    return sample


async def test_pack_and_daily_sessions_never_embed(api):
    """Neither path ranks by similarity, so a slow API must not touch them."""
    slow = api("slow")
    pack = _question("p1", pack_id="pack-1", review_status="pending_review")
    daily = _question("d1")
    retriever = QuestionRetriever(question_store=_Store([pack, daily]))

    pack_q = await asyncio.wait_for(
        retriever.get_next_question(
            QuizSession(session_id="s", language="en", pack_id="pack-1")
        ),
        GUARD_S,
    )
    daily_q = await asyncio.wait_for(
        retriever.get_next_question(
            QuizSession(
                session_id="d",
                language="en",
                daily_challenge_date="2026-11-17",
                fixed_question_ids=["d1"],
            )
        ),
        GUARD_S,
    )

    assert (pack_q.id, daily_q.id) == ("p1", "d1")
    assert slow.calls == []
