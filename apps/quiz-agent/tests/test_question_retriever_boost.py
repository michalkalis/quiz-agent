"""#195 — fresh-question 2× boost in QuestionRetriever's final pick.

Founder 2026-10-08: a topical question should come up ~2× as often as an
ordinary one, and ONLY while its window is open. So the pick weight must be
exactly `BOOST_WEIGHT` for a live boost and exactly 1 once `boost_until` has
passed (the question then behaves like an ordinary one — it is not removed,
that is the separate #76 expiry). The seeded frequency test proves every pick
site actually uses the weights rather than a plain `random.choice`.
"""

import random
from datetime import datetime, timedelta, timezone

import pytest
from app.retrieval import question_retriever as qr
from app.retrieval.question_retriever import (
    BOOST_WEIGHT,
    QuestionRetriever,
    pick_weight,
)
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

NOW = datetime.now(timezone.utc)


def _q(qid: str, boost_until=None, topic: str = "Film") -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        correct_answer="answer",
        topic=topic,
        category="entertainment",
        difficulty="medium",
        boost_until=boost_until,
    )


def test_live_boost_weighs_boost_weight_expired_and_none_weigh_one() -> None:
    assert BOOST_WEIGHT == 2.0
    assert pick_weight(_q("a", NOW + timedelta(days=3)), NOW) == BOOST_WEIGHT
    assert pick_weight(_q("b", NOW - timedelta(seconds=1)), NOW) == 1.0
    assert pick_weight(_q("c"), NOW) == 1.0
    # A naive timestamp is read as UTC, never crashes the hot path.
    naive_future = (NOW + timedelta(days=1)).replace(tzinfo=None)
    assert pick_weight(_q("d", naive_future), NOW) == BOOST_WEIGHT


def _share_of_boosted(pick, n: int = 6000) -> float:
    random.seed(195)
    return sum(pick() == "boosted" for _ in range(n)) / n


def test_first_question_pick_favours_boosted_about_2x() -> None:
    """One boosted vs one ordinary candidate → ~2/3 vs 1/3 (2× odds), not 1/2."""
    pool = [_q("boosted", NOW + timedelta(days=30)), _q("plain")]
    share = _share_of_boosted(lambda: qr.weighted_pick(pool).id)
    assert 0.63 < share < 0.70


def test_expired_boost_is_an_ordinary_coin_flip() -> None:
    pool = [_q("boosted", NOW - timedelta(days=1)), _q("plain")]
    share = _share_of_boosted(lambda: qr.weighted_pick(pool).id)
    assert 0.47 < share < 0.53


def test_top5_tuples_and_topic_fallback_use_the_weights() -> None:
    """The diverse top-5 pick weighs `(question, score)` tuples by the
    question; the topic fallback picks over plain questions — both weighted."""
    tuples = [(_q("boosted", NOW + timedelta(days=30)), 0.9), (_q("plain"), 0.8)]
    share = _share_of_boosted(
        lambda: qr.weighted_pick(tuples, key=lambda c: c[0])[0].id
    )
    assert 0.63 < share < 0.70

    retriever = QuestionRetriever(question_store=object())  # type: ignore[arg-type]
    session = QuizSession(session_id="s", current_difficulty="medium", language="en")
    pool = [_q("boosted", NOW + timedelta(days=30)), _q("plain")]
    share = _share_of_boosted(
        lambda: retriever._select_diverse_by_topic(pool, session).id
    )
    assert 0.63 < share < 0.70


@pytest.mark.asyncio
async def test_first_question_selection_path_is_weighted(monkeypatch) -> None:
    """`_select_with_semantic_diversity` with no history goes through the
    weighted pick, not `random.choice`."""
    retriever = QuestionRetriever(question_store=object())  # type: ignore[arg-type]

    async def _no_cap(candidates, session):
        return candidates

    monkeypatch.setattr(retriever, "_apply_image_cap", _no_cap)
    session = QuizSession(session_id="s", current_difficulty="medium", language="en")
    pool = [_q("boosted", NOW + timedelta(days=30)), _q("plain")]
    random.seed(195)
    picks = [
        (await retriever._select_with_semantic_diversity(pool, session)).id
        for _ in range(3000)
    ]
    assert 0.63 < picks.count("boosted") / len(picks) < 0.70
