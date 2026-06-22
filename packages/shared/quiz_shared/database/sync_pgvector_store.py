"""Sync adapter over the async `PgvectorQuestionStore`.

Bridges synchronous `QuestionStore` callers to the async-only pgvector
store via a dedicated background event loop. Two consumers share it:

- **quiz-agent voice-quiz read path** (#36 task 2.20): `QuestionRetriever`
  is sync (request hot path), so `get`/`count`/`search` adapt here.
- **quiz-pack-api `DedupStage`** (#42 task 42.27): the `QuestionStore`
  Protocol declares `find_duplicates` sync and `DedupStage.run` calls it
  synchronously, so duplicate detection against the canonical pgvector
  corpus also routes through this facade.

Why a background loop and not `asyncio.run`?
  Both callers invoke these methods from inside a *running* event loop
  (FastAPI async handlers; the worker/CLI pipeline's async `Stage.run`).
  Calling `asyncio.run` from such a thread raises `RuntimeError`. Running
  the coroutine on a separate, dedicated loop via
  `run_coroutine_threadsafe` works in both sync and async caller contexts,
  at the cost of blocking the calling thread until the query returns.
"""

from __future__ import annotations

import asyncio
import threading
from typing import Any, Dict, List, Optional, Tuple

from ..models.question import Question
from .pgvector_client import PgvectorQuestionStore


class _BackgroundLoop:
    """Dedicated daemon-thread event loop for bridging sync→async calls."""

    def __init__(self) -> None:
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()

    def _ensure_started(self) -> asyncio.AbstractEventLoop:
        if self._loop is not None:
            return self._loop
        with self._lock:
            if self._loop is not None:
                return self._loop
            loop = asyncio.new_event_loop()
            thread = threading.Thread(
                target=loop.run_forever,
                name="pgvector-bridge-loop",
                daemon=True,
            )
            thread.start()
            self._loop = loop
            self._thread = thread
            return loop

    def run(self, coro: Any) -> Any:
        loop = self._ensure_started()
        future = asyncio.run_coroutine_threadsafe(coro, loop)
        return future.result()


class SyncPgvectorStore:
    """Sync facade over `PgvectorQuestionStore`.

    Exposes the read-path methods `QuestionRetriever` uses (`get`, `count`,
    `search`) plus `find_duplicates` for `DedupStage`. Write methods (`add`,
    `upsert`, `delete`) are not provided — neither consumer writes through
    this facade (the voice-quiz read path does not write; quiz-pack-api
    persists via `PersistStage`).
    """

    def __init__(self, async_store: PgvectorQuestionStore) -> None:
        self._async = async_store
        self._bridge = _BackgroundLoop()

    def get(self, question_id: str) -> Optional[Question]:
        return self._bridge.run(self._async.get(question_id))

    def count(self, filters: Optional[Dict[str, Any]] = None) -> int:
        return self._bridge.run(self._async.count(filters=filters))

    def search(
        self,
        query_text: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        n_results: int = 10,
        excluded_ids: Optional[List[str]] = None,
    ) -> List[Question]:
        return self._bridge.run(
            self._async.search(
                query_text=query_text,
                filters=filters,
                n_results=n_results,
                excluded_ids=excluded_ids,
            )
        )

    def get_all(self, limit: int = 1000) -> List[Question]:
        # Not used by QuestionRetriever; provided for QuestionStore protocol
        # conformance so future callers don't trip over AttributeError.
        raise NotImplementedError(
            "SyncPgvectorStore.get_all not implemented — voice-quiz read path "
            "does not iterate the full collection."
        )

    def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> List[Tuple[Question, float]]:
        return self._bridge.run(
            self._async.find_duplicates(question_text, threshold=threshold)
        )
