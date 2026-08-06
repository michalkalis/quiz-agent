"""#151 — the serve read path must overlap, not queue behind one bridge thread.

Before this, every question lookup in the process (first question, next question,
TTS re-read, resubmission) crossed one ``SyncPgvectorStore`` background loop, and
each lookup parked that loop for a full *synchronous* embedding round trip before
touching Postgres. Two players quizzing at once therefore serialized: a hard
throughput ceiling of roughly one retrieval per embedding round trip for the whole
process, dressed up as parallelism by ``asyncio.to_thread`` wrappers that only
freed the FastAPI loop.

The tests below pin the fix by contrast: the same store, the same fake latency,
measured through the async path (overlaps) and through the old sync facade
(serializes). ``test_the_sync_facade_still_serializes`` is what makes the
overlap assertion meaningful — it is the pre-#151 shape, still executable, and it
shows the number the new path must beat.
"""

from __future__ import annotations

import asyncio
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, List

import pytest

from app.retrieval.question_retriever import QuestionRetriever
from quiz_shared.database.pgvector_client import PgvectorQuestionStore
from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

# One "embedding round trip". Small enough to keep the suite fast, large enough
# that N of them in series is unmistakably distinguishable from N in parallel.
EMBED_DELAY = 0.1
CONCURRENCY = 5


def _row(qid: str) -> dict:
    """One ``questions`` row as ``_row_to_question`` reads it."""
    return {
        "id": "11111111-1111-4111-8111-111111111111",
        "question": f"Question {qid}?",
        "type": "text",
        "possible_answers": None,
        "correct_answer": "answer",
        "headline_answer": None,
        "alternative_answers": [],
        "topic": "Geography",
        "category": "general",
        "difficulty": "medium",
        "tags": [],
        "language_dependent": False,
        "age_appropriate": None,
        "language": "en",
        "pack_id": None,
        "source": "test",
        "source_url": None,
        "source_excerpt": None,
        "review_status": "approved",
        # Carrying an embedding keeps diversity scoring off the embedder — the
        # only remote call under test is the query embedding.
        "embedding": [0.0] * 8,
        "embedding_model": "text-embedding-3-small",
        "embedding_dim": 8,
        "usage_count": 0,
        "created_at": datetime.now(timezone.utc),
        "expires_at": None,
        "freshness_tag": None,
        "explanation": None,
        "media_url": None,
        "image_subtype": None,
        "provenance": None,
    }


class _FakeResult:
    def __init__(self, rows: List[dict]) -> None:
        self._rows = rows

    def mappings(self):
        return self

    def all(self):
        return self._rows

    def first(self):
        return self._rows[0] if self._rows else None

    def scalar_one(self):
        return len(self._rows)


class _FakeSession:
    """Stands in for the DB leg: instant, so the delay under test is the embed."""

    async def __aenter__(self) -> "_FakeSession":
        return self

    async def __aexit__(self, *exc: Any) -> bool:
        return False

    async def execute(self, *_args: Any, **_kwargs: Any) -> _FakeResult:
        return _FakeResult([_row("q1")])


def _store(embedder) -> PgvectorQuestionStore:
    return PgvectorQuestionStore(session_factory=_FakeSession, embedder=embedder)


async def _slow_async_embedder(_text: str) -> List[float]:
    """The remote embedding call, awaited — yields for its whole duration."""
    await asyncio.sleep(EMBED_DELAY)
    return [0.0] * 8


def _blocking_embedder(_text: str) -> List[float]:
    """The pre-#151 shape: a synchronous HTTP call that parks its thread."""
    time.sleep(EMBED_DELAY)
    return [0.0] * 8


def _session() -> QuizSession:
    return QuizSession(session_id="s_concurrency", user_id="u_1", max_questions=10)


async def test_concurrent_retrievals_overlap_on_the_async_path():
    """N players asking at once must cost about ONE embedding round trip.

    This is the whole point of #151: the retriever awaits the async store, so the
    embedding waits interleave. On the pre-change code these same N calls crossed
    one bridge loop that a synchronous embedder held for its full duration —
    ``test_the_sync_facade_still_serializes`` below measures exactly that shape
    and shows it costs N delays instead.
    """
    retriever = QuestionRetriever(question_store=_store(_slow_async_embedder))

    started = time.perf_counter()
    results = await asyncio.gather(
        *(retriever.get_next_question(_session()) for _ in range(CONCURRENCY))
    )
    elapsed = time.perf_counter() - started

    assert all(q is not None for q in results)
    # One delay (plus slack), not CONCURRENCY delays.
    assert elapsed < EMBED_DELAY * 2, (
        f"{CONCURRENCY} retrievals took {elapsed:.3f}s — they are serializing, "
        f"not overlapping (one embedding round trip is {EMBED_DELAY}s)"
    )


async def test_the_sync_facade_still_serializes():
    """The contrast case, and the reason the assertion above is meaningful.

    ``SyncPgvectorStore`` is still the worker's path. Its one background loop
    plus a blocking embedder is the pre-#151 serve-path shape: the same N calls,
    off the request loop via ``to_thread`` exactly as the routes used to do it,
    still cost N delays. If this ever drops to ~one delay the comparison above
    has stopped proving anything.
    """
    sync_store = SyncPgvectorStore(_store(_blocking_embedder))

    started = time.perf_counter()
    await asyncio.gather(
        *(
            asyncio.to_thread(sync_store.search, "quiz question", None, 5, None)
            for _ in range(CONCURRENCY)
        )
    )
    elapsed = time.perf_counter() - started

    assert elapsed > EMBED_DELAY * (CONCURRENCY - 1), (
        f"{CONCURRENCY} bridged retrievals took only {elapsed:.3f}s — the bridge "
        "is no longer the serializing shape this test documents"
    )


async def test_bridge_wait_is_bounded():
    """A stalled coroutine must raise, not park the caller's thread forever.

    ``future.result()`` carried no timeout, so a hung retrieval silently held the
    calling thread (the worker's dedup stage would read as "still running").
    """

    class _HangingStore:
        async def get(self, _question_id: str):
            await asyncio.Event().wait()  # never completes

    sync_store = SyncPgvectorStore(_HangingStore(), timeout=0.05)

    started = time.perf_counter()
    with pytest.raises(TimeoutError, match="did not complete within"):
        await asyncio.to_thread(sync_store.get, "q1")
    assert time.perf_counter() - started < 2.0


def test_no_serve_path_retrieval_is_offloaded_to_a_thread():
    """Inventory (#151 done criterion 1): the ``asyncio.to_thread`` wrappers that
    hid the serialized bridge are gone from the application code."""
    app_dir = Path(__file__).resolve().parents[1] / "app"
    offenders = [
        str(path.relative_to(app_dir))
        for path in app_dir.rglob("*.py")
        if "to_thread" in path.read_text() and "question_retriever" in path.read_text()
    ]
    assert not offenders, (
        f"serve-path retrieval is still being pushed onto a worker thread: {offenders}"
    )
