"""#235 — the unranked next-question pick keeps every serving rule, in real SQL.

When the embeddings API is slow, the next question is picked without
similarity ranking. Only the ranking may go: the player must still get a
question in their language and chosen category, approved (App Store builds
never see unreviewed rows), never one they were already asked, never someone's
private pack question, and never an expired one or one a ranked search could
not return (no stored embedding). Difficulty relaxes last, exactly as the
ranked fallback chain does. Reuses the private scratch database of the
stock-count tests.
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import timedelta

import pytest
from app.retrieval import question_retriever as retriever_module
from app.retrieval.question_retriever import QuestionRetriever, embed_query
from quiz_shared.models.session import QuizSession
from sqlalchemy import text

from tests.db.test_question_stock_counts import NOW, _question, store  # noqa: F401

pytestmark = pytest.mark.asyncio


@pytest.fixture
def slow_embeddings(monkeypatch):
    async def never_answers(text, **kwargs):
        await asyncio.Event().wait()

    monkeypatch.setattr(retriever_module, "generate_embedding_async", never_answers)
    monkeypatch.setattr(retriever_module, "QUERY_EMBED_TIMEOUT_S", 0.01)


async def test_unranked_pick_serves_only_what_a_ranked_pick_could(
    store,  # noqa: F811
    slow_embeddings,
):
    history = {"category": "history", "difficulty": "easy"}
    rows = {
        "target": _question(**history),
        "harder": _question(category="history", difficulty="hard"),
        "asked": _question(**history),
        "pending": _question(review_status="pending_review", **history),
        "other_category": _question(category="science", difficulty="easy"),
        "pack": _question(pack_id=str(uuid.uuid4()), **history),
        "other_language": _question(language="sk", **history),
        "expired": _question(expires_at=NOW - timedelta(days=1), **history),
        "no_embedding": _question(**history),
    }
    for q in rows.values():
        assert await store.upsert(q) is True
    # Written with a vector (upsert would embed a vector-less row), then cleared.
    async with store._session_factory() as db:
        await db.execute(
            text("UPDATE questions SET embedding = NULL WHERE id = :id"),
            {"id": uuid.UUID(rows["no_embedding"].id)},
        )
        await db.commit()
    names = {q.id: name for name, q in rows.items()}
    retriever = QuestionRetriever(question_store=store.with_embedder(embed_query))
    session = QuizSession(
        session_id="s",
        language="en",
        current_difficulty="easy",
        preferred_categories=["history"],
        asked_question_ids=[rows["asked"].id],
    )

    picks = set()
    for _ in range(5):  # the sample is random; every draw must obey the rules
        q = await asyncio.wait_for(retriever.get_next_question(session), 2.0)
        picks.add(names[q.id])
    assert picks == {"target"}

    # Once the only easy question is asked, difficulty relaxes (and only that).
    session.asked_question_ids.append(rows["target"].id)
    q = await asyncio.wait_for(retriever.get_next_question(session), 2.0)
    assert names[q.id] == "harder"

    session.asked_question_ids.append(rows["harder"].id)
    assert await asyncio.wait_for(retriever.get_next_question(session), 2.0) is None
