"""Read-path expiry-filter activation guard for QuestionRetriever (issue #76, F-3b).

`QuestionRetriever.get_next_question` already drops expired candidates in-memory
via `Question.is_expired()` before selection — on the primary semantic path
(question_retriever.py:118) and the fallback path (:128). Today nothing writes
`expires_at`, so `is_expired()` returns False for every row and the filter is a
DORMANT no-op. Issue #76 F-3b (entertainment category) becomes the first writer
of `expires_at`, which will silently *activate* this filter on the live read
path.

These tests pin the dormancy claim as a correctness guard: the filter must drop
NOTHING while `expires_at` is None, and — once F-3b starts stamping it — must
drop exactly the past-expiry rows while keeping future/None-expiry rows
servable. The observation seam is the candidate list handed to selection, which
equals the post-filter survivor set (the filter runs immediately before
selection in `get_next_question`), plus the public return value.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

from app.retrieval.question_retriever import QuestionRetriever


def _make_question(qid: str, *, expires_at=None) -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        type="text",
        correct_answer="answer",
        topic="Entertainment",
        category="general",
        difficulty="medium",
        review_status="approved",
        expires_at=expires_at,
    )


def _session() -> QuizSession:
    # No asked_question_ids → selection collapses to a single deterministic step,
    # keeping the test focused on the expiry filter, not diversity scoring.
    return QuizSession(
        session_id="sess_expiry", current_difficulty="medium", language="en"
    )


def _retriever_capturing_survivors(search_results) -> QuestionRetriever:
    """Build a retriever whose mocked store returns ``search_results`` and whose
    selection stage is spied so we can read back the exact post-filter survivor
    set.

    ``search_results`` is either a flat list (returned for every ``store.search``
    call) or a list-of-lists used as sequential side effects (primary call, then
    fallback call) to reach the fallback path.
    """
    store = MagicMock()
    if search_results and isinstance(search_results[0], list):
        store.search.side_effect = search_results
    else:
        store.search.return_value = search_results
    retriever = QuestionRetriever(question_store=store)
    # get_next_question calls _select_with_semantic_diversity(candidates, session)
    # with the survivor set immediately after the expiry filter — capture it and
    # return a concrete question so the public return value stays non-None.
    retriever._select_with_semantic_diversity = MagicMock(
        side_effect=lambda candidates, session: candidates[0]
    )
    return retriever


def _survivor_ids(retriever: QuestionRetriever) -> list[str]:
    candidates_arg = retriever._select_with_semantic_diversity.call_args.args[0]
    return [c.id for c in candidates_arg]


def test_dormant_filter_is_a_noop_when_expires_at_is_none():
    """F-3b dormancy: while no row carries ``expires_at``, the expiry filter must
    drop NOTHING — every candidate stays servable. If this fails, the filter is
    silently discarding live questions before F-3b even writes a date."""
    candidates = [_make_question("q1"), _make_question("q2"), _make_question("q3")]
    retriever = _retriever_capturing_survivors(candidates)

    result = retriever.get_next_question(_session())

    assert result is not None
    assert _survivor_ids(retriever) == ["q1", "q2", "q3"]  # zero dropped


def test_past_expiry_row_is_dropped_and_rest_remain_servable():
    """F-3b activation (primary path): once ``expires_at`` is written, a
    past-expiry row must be the ONLY thing dropped; the un-dated / still-valid
    rows must remain servable so the driver still gets a question. This is the
    filter's whole reason to exist."""
    past = datetime.now(timezone.utc) - timedelta(days=1)
    candidates = [
        _make_question("q_expired", expires_at=past),
        _make_question("q_ok_a"),
        _make_question("q_ok_b"),
    ]
    retriever = _retriever_capturing_survivors(candidates)

    result = retriever.get_next_question(_session())

    survivors = _survivor_ids(retriever)
    assert survivors == ["q_ok_a", "q_ok_b"]  # exactly the past-expiry row dropped
    assert "q_expired" not in survivors
    assert result is not None
    assert result.id != "q_expired"  # the expired row can never be returned


def test_future_expiry_row_is_retained():
    """F-3b activation (primary path): a not-yet-expired row (future
    ``expires_at``) must survive the filter — F-3b's time-boxed entertainment
    questions are meant to be served until their expiry, not pre-emptively
    dropped the moment a date is stamped."""
    future = datetime.now(timezone.utc) + timedelta(days=7)
    candidates = [_make_question("q_future", expires_at=future)]
    retriever = _retriever_capturing_survivors(candidates)

    result = retriever.get_next_question(_session())

    assert _survivor_ids(retriever) == ["q_future"]  # retained
    assert result is not None
    assert result.id == "q_future"  # servable


def test_fallback_path_also_drops_past_expiry():
    """F-3b activation (fallback path, question_retriever.py:128): when primary
    semantic search returns nothing and retrieval falls through to the fallback
    strategies, the same expiry filter must apply — a past-expiry row must still
    be dropped there, else expired questions leak back in on the exact path taken
    when the library is thin."""
    past = datetime.now(timezone.utc) - timedelta(days=1)
    fallback_candidates = [
        _make_question("q_expired", expires_at=past),
        _make_question("q_ok"),
    ]
    # Primary semantic search returns nothing → retrieval enters
    # _fallback_retrieval; its first store.search yields these candidates, which
    # are the line-128 filter's input.
    retriever = _retriever_capturing_survivors([[], fallback_candidates])

    result = retriever.get_next_question(_session())

    survivors = _survivor_ids(retriever)
    assert survivors == ["q_ok"]  # past-expiry row dropped on the fallback path
    assert "q_expired" not in survivors
    assert result is not None
    assert result.id == "q_ok"
