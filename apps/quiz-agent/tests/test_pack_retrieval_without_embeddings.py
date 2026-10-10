"""A custom-pack session must serve its pack's questions even though they carry
no embedding (prod incident 2026-10-10).

Why: quiz-pack-api's PersistStage writes pack rows without an `embedding`, and
`PgvectorQuestionStore.search` silently skips embedding-less rows whenever it
is given a query text (it ranks by cosine distance). The retriever ran every
pack session through that semantic search, so a paid pack with 13 ready
questions served none: the player sat on "the pack is still being written"
forever while the server logged "No questions available".

The fake store below keeps exactly that contract (query text => only rows with
an embedding) so these tests fail the way prod did, regardless of the player's
difficulty or quiz language.
"""

from __future__ import annotations

import pytest
from app.retrieval import question_retriever as retriever_module
from app.retrieval.question_retriever import QuestionRetriever
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

PACK_ID = "9eb32530-0000-4000-8000-00000000beef"


class _ContractStore:
    """In-memory store honouring PgvectorQuestionStore.search's embedding rule."""

    def __init__(self, rows: list[Question]):
        self._rows = {q.id: q for q in rows}

    async def search(
        self, query_text=None, filters=None, n_results=10, excluded_ids=None
    ):
        filters = filters or {}
        excluded = set(excluded_ids or [])
        out = []
        for q in self._rows.values():
            if q.id in excluded:
                continue
            if "pack_id" in filters and q.pack_id != filters["pack_id"]:
                continue
            if query_text and q.embedding is None:
                continue  # cosine ordering skips embedding-less rows
            out.append(q)
        return out[:n_results]

    async def get(self, question_id):
        return self._rows.get(question_id)

    async def count(self, filters=None):
        return len(self._rows)


def _pack_question(qid: str, difficulty: str) -> Question:
    return Question(
        id=qid,
        question=f"Absurd question {qid}?",
        type="text",
        correct_answer="answer",
        topic="Absurdné otázky",
        category="general",
        difficulty=difficulty,
        language="en",
        pack_id=PACK_ID,
        review_status="pending_review",
        embedding=None,  # what PersistStage writes for every pack row
    )


def _pack_session(**overrides) -> QuizSession:
    session = QuizSession(
        session_id="sess_pack",
        current_difficulty="medium",
        language="en",
        pack_id=PACK_ID,
    )
    for key, value in overrides.items():
        setattr(session, key, value)
    return session


@pytest.fixture(autouse=True)
def _no_embedding_calls(monkeypatch):
    """A pack pick must not embed on the hot path either: on-the-fly embedding
    of every candidate would cost one OpenAI round trip per pack question."""

    async def _boom(*_args, **_kwargs):
        raise AssertionError("pack retrieval must not generate embeddings")

    monkeypatch.setattr(retriever_module, "generate_embedding_async", _boom)


def _retriever(rows: list[Question]) -> QuestionRetriever:
    return QuestionRetriever(question_store=_ContractStore(rows))


async def test_first_pack_question_is_served_without_embeddings():
    rows = [_pack_question("q1", "easy"), _pack_question("q2", "hard")]
    retriever = _retriever(rows)

    question = await retriever.get_next_question(_pack_session())

    assert question is not None, "ready pack questions must be served"
    assert question.pack_id == PACK_ID


async def test_next_pack_question_after_one_answered():
    rows = [_pack_question(f"q{i}", "medium") for i in range(1, 6)]
    retriever = _retriever(rows)
    session = _pack_session(asked_question_ids=["q1"])

    question = await retriever.get_next_question(session)

    assert question is not None
    assert question.id != "q1"


async def test_pack_serves_regardless_of_player_difficulty_and_language():
    """The player's own settings (SK quiz, hard difficulty, categories) never
    gate a pack: the pack is the curated set they ordered."""
    rows = [_pack_question("q1", "easy")]
    retriever = _retriever(rows)
    session = _pack_session(current_difficulty="hard", preferred_categories=["sports"])

    question = await retriever.get_next_question(session)

    assert question is not None and question.id == "q1"
