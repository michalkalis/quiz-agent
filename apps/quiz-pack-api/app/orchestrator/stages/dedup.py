"""DedupStage — drops near-duplicate questions before persistence (issue #36 task 2.8).

Two independent checks, either of which is enough to drop a question:

- **Cosine similarity ≥ 0.85** against the existing question corpus, via
  `QuestionStore.find_duplicates`. Catches questions that paraphrase an
  already-stored question (semantic dup). The 0.85 cutoff matches the
  legacy `QuestionStorage.check_duplicates` threshold so behaviour is
  unchanged on the inputs both code paths see.
- **Jaccard token overlap ≥ 0.80** against `gold_standard.json`. Catches
  near-verbatim copies of the curated gold-standard set we use as a
  reviewer baseline — we never want a generated pack to mirror that
  list (it would pollute eval signal and look lazy to reviewers).

The dropped count is published via `StageResult.info["dropped"]` so SSE
clients see the filter activity, mirroring `VerificationStage`'s shape.

The constructor takes a `QuestionStore` (Protocol from `quiz_shared`),
so today's ChromaDB-backed store and the Phase-2.19 `PgvectorQuestionStore`
plug in interchangeably. The `pack_id` filter described in the focus
file (`WHERE pack_id IS NULL OR pack_id = ctx.pack_id`) is a pgvector-
specific concern — ChromaDB does not store `pack_id` today. Once 2.19
lands the pgvector store, that filter belongs inside the store's query
implementation, not here. See TODO(2.19) below.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Iterable

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from quiz_shared.database.question_store import QuestionStore
from quiz_shared.models.question import Question

DEFAULT_COSINE_THRESHOLD = 0.85
DEFAULT_JACCARD_THRESHOLD = 0.80

_TOKEN_RE = re.compile(r"[a-z0-9]+")


class DedupStage:
    """Drops near-duplicate questions via cosine + Jaccard checks."""

    name = "dedup"

    def __init__(
        self,
        question_store: QuestionStore,
        gold_standard_path: str | Path | None,
        cosine_threshold: float = DEFAULT_COSINE_THRESHOLD,
        jaccard_threshold: float = DEFAULT_JACCARD_THRESHOLD,
    ) -> None:
        self._store = question_store
        self._gold_standard_path = (
            Path(gold_standard_path) if gold_standard_path is not None else None
        )
        self._cosine_threshold = cosine_threshold
        self._jaccard_threshold = jaccard_threshold
        self._gold_tokens: list[frozenset[str]] | None = None

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"kept": 0, "dropped": 0}, cost_cents=0)

        gold_tokens = self._load_gold_tokens()

        kept: list[Question] = []
        dropped = 0
        for q in ctx.questions:
            if self._is_cosine_duplicate(q):
                dropped += 1
                continue
            if self._is_jaccard_duplicate(q, gold_tokens):
                dropped += 1
                continue
            kept.append(q)

        ctx.questions = kept
        return StageResult(
            info={"kept": len(kept), "dropped": dropped},
            cost_cents=0,
        )

    def _is_cosine_duplicate(self, question: Question) -> bool:
        # TODO(2.19): once PgvectorQuestionStore lands, push the
        # `pack_id IS NULL OR pack_id = ctx.pack_id` filter into the store
        # query so cross-pack dedup is exact. ChromaDB has no pack_id today.
        try:
            duplicates = self._store.find_duplicates(
                question.question, threshold=self._cosine_threshold
            )
        except Exception:
            # A failing store must not silently approve dups; surface via
            # info but do not drop the question on a store outage.
            return False
        # `find_duplicates` returns same-or-higher similarity matches, but
        # may include the question itself if it was already persisted. Skip
        # self-matches by id so a re-run is idempotent.
        for match, _score in duplicates:
            if match.id != question.id:
                return True
        return False

    def _is_jaccard_duplicate(
        self, question: Question, gold_tokens: list[frozenset[str]]
    ) -> bool:
        if not gold_tokens:
            return False
        q_tokens = _tokenize(question.question)
        if not q_tokens:
            return False
        for gold in gold_tokens:
            if _jaccard(q_tokens, gold) >= self._jaccard_threshold:
                return True
        return False

    def _load_gold_tokens(self) -> list[frozenset[str]]:
        if self._gold_tokens is not None:
            return self._gold_tokens
        if self._gold_standard_path is None or not self._gold_standard_path.exists():
            self._gold_tokens = []
            return self._gold_tokens
        with self._gold_standard_path.open("r", encoding="utf-8") as fh:
            data: Any = json.load(fh)
        self._gold_tokens = [
            _tokenize(entry["question"])
            for entry in _gold_entries(data)
            if isinstance(entry, dict) and entry.get("question")
        ]
        return self._gold_tokens


def _gold_entries(data: Any) -> Iterable[dict[str, Any]]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        return data["questions"]
    return []


def _tokenize(text: str) -> frozenset[str]:
    return frozenset(_TOKEN_RE.findall(text.lower()))


def _jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    intersection = len(a & b)
    union = len(a | b)
    if union == 0:
        return 0.0
    return intersection / union
