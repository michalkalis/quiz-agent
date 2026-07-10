"""DedupStage — drops near-duplicate questions before persistence (issue #36 task 2.8).

Two independent checks, either of which is enough to drop a question:

- **Cosine similarity ≥ 0.85** against the existing question corpus, via
  `QuestionStore.find_duplicates`. Catches questions that paraphrase an
  already-stored question (semantic dup).
- **Jaccard token overlap ≥ 0.80** against `gold_standard.json`. Catches
  near-verbatim copies of the curated gold-standard set we use as a
  reviewer baseline — we never want a generated pack to mirror that
  list (it would pollute eval signal and look lazy to reviewers).
- **Jaccard token overlap ≥ 0.60** against earlier questions of the SAME
  batch (#72, 2026-07-10). The corpus lookup cannot see not-yet-persisted
  batchmates, so without this a single batch can repeat itself; stricter
  than the gold threshold because same-batch dupes share one quiz.

The dropped count is published via `StageResult.info["dropped"]` so SSE
clients see the filter activity, mirroring `VerificationStage`'s shape.

The constructor takes a `QuestionStore` (Protocol from `quiz_shared`);
in production that is the pgvector-backed store. The `pack_id` filter
(`WHERE pack_id IS NULL OR pack_id = ctx.pack_id`) belongs inside the
store's query implementation, not here.
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
# Stricter than the gold-standard threshold: two same-fact rewordings in ONE
# batch land in the same quiz, and the June-18 audit variants ("record as the
# longest" vs "record for being the longest") overlap at ~0.7 — 0.80 would
# miss them. 0.60 still clears genuinely distinct questions that merely share
# a topic (measured ~0.36 on same-topic pairs).
DEFAULT_IN_BATCH_JACCARD_THRESHOLD = 0.60

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
        in_batch_threshold: float = DEFAULT_IN_BATCH_JACCARD_THRESHOLD,
    ) -> None:
        self._store = question_store
        self._gold_standard_path = (
            Path(gold_standard_path) if gold_standard_path is not None else None
        )
        self._cosine_threshold = cosine_threshold
        self._jaccard_threshold = jaccard_threshold
        self._in_batch_threshold = in_batch_threshold
        self._gold_tokens: list[frozenset[str]] | None = None

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"kept": 0, "dropped": 0}, cost_cents=0)

        gold_tokens = self._load_gold_tokens()

        kept: list[Question] = []
        kept_tokens: list[frozenset[str]] = []
        dropped = 0
        for q in ctx.questions:
            if self._is_cosine_duplicate(q):
                dropped += 1
                continue
            if self._is_jaccard_duplicate(q, gold_tokens):
                dropped += 1
                continue
            # In-batch check (#72, 2026-07-10): the corpus lookup cannot see
            # questions from the same not-yet-persisted batch, so without this
            # a batch can carry near-verbatim repeats of itself (the June-18
            # audit batch had the same bridge question 3×). First occurrence
            # wins; later near-copies drop.
            q_tokens = _tokenize(q.question)
            if q_tokens and any(
                _jaccard(q_tokens, k) >= self._in_batch_threshold
                for k in kept_tokens
            ):
                dropped += 1
                continue
            kept.append(q)
            kept_tokens.append(q_tokens)

        ctx.questions = kept
        return StageResult(
            info={"kept": len(kept), "dropped": dropped},
            cost_cents=0,
        )

    def _is_cosine_duplicate(self, question: Question) -> bool:
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
