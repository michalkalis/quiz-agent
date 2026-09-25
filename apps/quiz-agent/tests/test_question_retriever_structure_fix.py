"""Unfixed SK/CS word order stays out of the beta (founder 2026-09-25).

~42 % of the stored Slovak/Czech translations copy the English word order
("…thanks to which thriller?"), so a listener in the car cannot tell what is
asked. Until each question sentence is rewritten, its translation carries a
`structure_fix` flag and the retriever must keep that question out of sessions
in THAT language — on the serve path and in the availability count alike, or
the quota probe would promise questions the serve path then refuses.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest
from app.retrieval.question_retriever import QuestionRetriever
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio


def _retriever(pending=("q_unfixed",)) -> QuestionRetriever:
    store = MagicMock()
    store.search = AsyncMock(
        return_value=[
            Question(
                id="q_fresh",
                question="Question?",
                type="text",
                correct_answer="a",
                topic="t",
                category="general",
                difficulty="medium",
                review_status="approved",
            )
        ]
    )
    store.count = AsyncMock(return_value=7)
    store.structure_fix_pending_ids = AsyncMock(return_value=list(pending))
    retriever = QuestionRetriever(question_store=store)
    retriever._select_with_semantic_diversity = AsyncMock(
        side_effect=lambda candidates, session: candidates[0]
    )
    return retriever


def _session(language: str, pack_id=None) -> QuizSession:
    s = QuizSession(session_id="s", current_difficulty="medium", language=language)
    s.pack_id = pack_id
    return s


async def test_slovak_session_excludes_unfixed_questions_when_serving():
    retriever = _retriever()
    await retriever.get_next_question(_session("sk"))
    assert "q_unfixed" in retriever._store.search.call_args.kwargs["excluded_ids"]
    retriever._store.structure_fix_pending_ids.assert_awaited_with("sk")


async def test_availability_count_excludes_them_too():
    retriever = _retriever()
    await retriever.count_available(_session("cs"))
    assert "q_unfixed" in retriever._store.count.call_args.kwargs["excluded_ids"]
    retriever._store.structure_fix_pending_ids.assert_awaited_with("cs")


async def test_english_session_is_untouched():
    """English is the source text — nothing to fix, nothing to hide."""
    retriever = _retriever()
    await retriever.get_next_question(_session("en"))
    assert "q_unfixed" not in retriever._store.search.call_args.kwargs["excluded_ids"]
    retriever._store.structure_fix_pending_ids.assert_not_awaited()


async def test_custom_pack_session_is_untouched():
    """A pack is generated in its own language, not translated."""
    retriever = _retriever()
    await retriever.get_next_question(_session("sk", pack_id="pack-1"))
    retriever._store.structure_fix_pending_ids.assert_not_awaited()


async def test_failed_lookup_degrades_to_serving_not_to_an_empty_quiz():
    retriever = _retriever()
    retriever._store.structure_fix_pending_ids = AsyncMock(
        side_effect=RuntimeError("db")
    )
    assert await retriever.get_next_question(_session("sk")) is not None
