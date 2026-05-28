"""Sync adapter over async `PgvectorQuestionStore` (#36 task 2.20).

The voice-quiz `QuestionRetriever` is sync (it predates the pgvector
cutover and is on the request hot path). The canonical
`PgvectorQuestionStore` is async-only. Rather than push async upward
through the retriever, flow service, and route handlers — out of scope
for Phase 2 per the issue plan — this adapter bridges sync calls to the
async store via a dedicated background event loop.

Why a background loop and not `asyncio.run`?
  `QuestionRetriever` methods are invoked from FastAPI async handlers,
  where the calling thread already owns a running event loop. Calling
  `asyncio.run` inside that thread raises `RuntimeError`. Running the
  coroutine on a separate, dedicated loop via
  `run_coroutine_threadsafe` works in both sync and async caller
  contexts.
"""

from __future__ import annotations

import asyncio
import threading
from typing import Any, Dict, List, Optional, Tuple

from quiz_shared.database.pgvector_client import PgvectorQuestionStore
from quiz_shared.models.question import Question


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
    """Sync facade implementing the read-path methods `QuestionRetriever` uses.

    Only the surface area the retriever touches (`get`, `count`, `search`)
    is exposed. Write methods (`add`, `upsert`, `delete`) are not provided
    — the voice-quiz read path does not write to the question store, and
    Phase 2 keeps ChromaDB as the write target for feedback updates.
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
        raise NotImplementedError(
            "SyncPgvectorStore.find_duplicates not implemented — duplicate "
            "detection lives in quiz-pack-api DedupStage."
        )
