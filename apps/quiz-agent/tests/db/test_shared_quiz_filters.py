"""#232 shared quiz — which rows a link may carry and serve, in real SQL.

A link carries someone else's questions to another build, so two gates must
hold: at creation only rows any player is served the same way (approved, no
image, no pack row, sk/cs English only with a stored translation), and at play
time the friend's own serving filters again — a row demoted since, or pending
review for TestFlight only, never reaches an App Store friend. A pack link
serves only that pack's rows, never one that was rejected since.
"""

from __future__ import annotations

import uuid

import pytest

from quiz_shared.models.session import QuizSession

from app.retrieval.question_retriever import QuestionRetriever
from app.shared_quiz import snapshot

from tests.db.test_question_stock_counts import _question, store  # noqa: F401

pytestmark = pytest.mark.asyncio


async def _put(store, **overrides):  # noqa: F811
    q = _question(**overrides)
    assert await store.upsert(q) is True
    return q.id


def _shared(ids, **fields):
    return QuizSession(
        session_id="s",
        user_id="friend",
        shared_quiz_id="share",
        fixed_question_ids=ids,
        max_questions=len(ids),
        **fields,
    )


async def test_snapshot_keeps_only_rows_every_player_gets_alike(store):  # noqa: F811
    approved = await _put(store)
    pending = await _put(store, review_status="pending_review")
    image = await _put(store, type="image")
    pack_row = await _put(store, pack_id=str(uuid.uuid4()))
    native_sk = await _put(store, language="sk")
    retriever = QuestionRetriever(question_store=store)

    played = [pending, approved, image, pack_row, native_sk]
    assert await snapshot.corpus_ids(retriever, played, "en") == [approved]
    # Slovak: the English row has no stored translation here, so only the
    # native row keeps the same wording for everyone.
    assert await snapshot.corpus_ids(retriever, played, "sk") == [native_sk]


async def test_play_time_uses_the_friends_own_review_gate(store):  # noqa: F811
    first = await _put(store)
    demoted = await _put(store)
    retriever = QuestionRetriever(question_store=store)
    ids = await snapshot.corpus_ids(retriever, [first, demoted], "en")
    assert ids == [first, demoted]
    # Sent back to review after the link was made (TestFlight-only now).
    await store.upsert(_question(id=demoted, review_status="pending_review"))

    app_store = _shared(ids, asked_question_ids=[first])
    assert await retriever.get_next_question(app_store) is None
    testflight = _shared(ids, asked_question_ids=[first], build_channel="testflight")
    assert (await retriever.get_next_question(testflight)).id == demoted


async def test_daily_set_is_still_read_as_is(store):  # noqa: F811
    """The daily challenge's own set is pre-filtered for every player; its
    fixed path is unchanged (no shared id → no second filter)."""
    row = await _put(store, review_status="pending_review")
    daily = QuizSession(
        session_id="d", daily_challenge_date="2026-11-13", fixed_question_ids=[row]
    )
    retriever = QuestionRetriever(question_store=store)
    assert (await retriever.get_next_question(daily)).id == row


async def test_pack_link_serves_only_that_packs_live_rows(store):  # noqa: F811
    pack, other_pack = str(uuid.uuid4()), str(uuid.uuid4())
    live = await _put(store, pack_id=pack, review_status="pending_review")
    rejected = await _put(store, pack_id=pack, review_status="rejected")
    foreign = await _put(store, pack_id=other_pack, review_status="pending_review")
    corpus = await _put(store)
    retriever = QuestionRetriever(question_store=store)

    assert await retriever.pack_question_ids(pack) == [live]
    assert await snapshot.pack_ids(retriever, pack, [rejected, live]) == [live]

    session = _shared([rejected, foreign, corpus, live], pack_id=pack)
    assert (await retriever.get_next_question(session)).id == live
    session.asked_question_ids = [live]
    assert await retriever.get_next_question(session) is None
