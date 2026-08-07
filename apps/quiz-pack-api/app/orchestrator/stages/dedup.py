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
- **Same-fact reuse in the SAME batch (#153 Phase 0.1)** — a fact may back
  only ONE question per pack. Two checks, either drops the later question:
  identical fact key (normalized ``source_url`` + normalized answer), which
  catches open-vs-MCQ rephrasings of one fact; and content-token Jaccard
  ≥ 0.35 over question+answer with stopwords removed, which catches
  paraphrases sharing the same substance (the 2026-08-07 batch's dup pairs
  measured 0.39–0.52 on this metric while its noisiest non-dup pair sat at
  0.21). Known residual: the same fact arriving from two different sources
  with disjoint wording (pair 15/17 of that batch, 0.12 here and 0.735 on
  embedding cosine vs a 0.738 non-dup pair) is NOT separable by any
  threshold — accepted gap, documented in issue #153.

The dropped count is published via `StageResult.info["dropped"]` so SSE
clients see the filter activity, mirroring `VerificationStage`'s shape.

The constructor takes an **async** duplicate finder; in production that is
`PgvectorQuestionStore` itself, awaited directly on the worker loop (#150).
It used to take the sync `QuestionStore` Protocol, which in the worker meant
`SyncPgvectorStore` — a `future.result()` bridge that parked the whole worker
event loop for the duration of every embedding + query, making #139's
heartbeat, per-stage belt and sweep inert exactly where a stall was most
likely. The `pack_id` filter (`WHERE pack_id IS NULL OR pack_id =
ctx.pack_id`) belongs inside the store's query implementation, not here.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any, Iterable, Protocol

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from quiz_shared.models.question import Question

DEFAULT_COSINE_THRESHOLD = 0.85
DEFAULT_JACCARD_THRESHOLD = 0.80
# Stricter than the gold-standard threshold: two same-fact rewordings in ONE
# batch land in the same quiz, and the June-18 audit variants ("record as the
# longest" vs "record for being the longest") overlap at ~0.7 — 0.80 would
# miss them. 0.60 still clears genuinely distinct questions that merely share
# a topic (measured ~0.36 on same-topic pairs).
DEFAULT_IN_BATCH_JACCARD_THRESHOLD = 0.60
# #153 Phase 0.1 — same-fact paraphrase check: question+answer tokens with
# stopwords removed. Calibrated on the 2026-08-07 rated batch: true dup pairs
# 0.39/0.46/0.52, noisiest non-dup pair 0.21 → 0.35 keeps a wide margin both
# ways.
DEFAULT_FACT_JACCARD_THRESHOLD = 0.35

_TOKEN_RE = re.compile(r"[a-z0-9]+")

logger = logging.getLogger(__name__)

# Function words only — topical content words must survive so the fact check
# compares substance, not phrasing.
_STOPWORDS = frozenset(
    "a an the of in on at to for is are was were be been do does did doing "
    "what which who whom whose how when where why your you it its not no "
    "but and or as by with from this that these those there here have has "
    "had can could will would may might most more".split()
)


class AsyncDuplicateFinder(Protocol):
    """The single async method `DedupStage` needs from a question store.

    Deliberately narrower than `quiz_shared.database.question_store.
    QuestionStore`: the stage never reads or writes questions, so requiring
    the full (sync) protocol is what pushed this call onto the blocking
    `SyncPgvectorStore` bridge in the first place.
    """

    async def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]: ...


class DedupStage:
    """Drops near-duplicate questions via cosine + Jaccard checks."""

    name = "dedup"

    def __init__(
        self,
        question_store: AsyncDuplicateFinder,
        gold_standard_path: str | Path | None,
        cosine_threshold: float = DEFAULT_COSINE_THRESHOLD,
        jaccard_threshold: float = DEFAULT_JACCARD_THRESHOLD,
        in_batch_threshold: float = DEFAULT_IN_BATCH_JACCARD_THRESHOLD,
        fact_jaccard_threshold: float = DEFAULT_FACT_JACCARD_THRESHOLD,
    ) -> None:
        self._store = question_store
        self._gold_standard_path = (
            Path(gold_standard_path) if gold_standard_path is not None else None
        )
        self._cosine_threshold = cosine_threshold
        self._jaccard_threshold = jaccard_threshold
        self._in_batch_threshold = in_batch_threshold
        self._fact_jaccard_threshold = fact_jaccard_threshold
        self._gold_tokens: list[frozenset[str]] | None = None

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"kept": 0, "dropped": 0}, cost_cents=0)

        gold_tokens = self._load_gold_tokens()

        kept: list[Question] = []
        kept_tokens: list[frozenset[str]] = []
        kept_fact_keys: set[tuple[str, str]] = set()
        kept_fact_tokens: list[frozenset[str]] = []
        dropped = 0
        fact_dropped = 0
        for q in ctx.questions:
            if await self._is_cosine_duplicate(q):
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
            # Same-fact reuse (#153 Phase 0.1): one fact backs one question
            # per pack, across formats and top-up rounds (top-up merges
            # survivors before this stage re-runs, so earlier rounds are in
            # `kept_*` here). First occurrence wins.
            fact_key = _fact_key(q)
            fact_tokens = _fact_tokens(q)
            if fact_key is not None and fact_key in kept_fact_keys:
                fact_dropped += 1
                logger.warning(
                    "DedupStage same-fact dropped id=%s (fact key reuse "
                    "url=%s answer=%s)",
                    q.id, fact_key[0], fact_key[1],
                )
                continue
            if fact_tokens and any(
                _jaccard(fact_tokens, k) >= self._fact_jaccard_threshold
                for k in kept_fact_tokens
            ):
                fact_dropped += 1
                logger.warning(
                    "DedupStage same-fact dropped id=%s (content overlap "
                    ">= %.2f with an earlier batchmate)",
                    q.id, self._fact_jaccard_threshold,
                )
                continue
            kept.append(q)
            kept_tokens.append(q_tokens)
            kept_fact_tokens.append(fact_tokens)
            if fact_key is not None:
                kept_fact_keys.add(fact_key)

        ctx.questions = kept
        return StageResult(
            info={
                "kept": len(kept),
                "dropped": dropped + fact_dropped,
                "fact_dropped": fact_dropped,
            },
            cost_cents=0,
        )

    async def _is_cosine_duplicate(self, question: Question) -> bool:
        try:
            duplicates = await self._store.find_duplicates(
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


def _normalize_answer(answer: Any) -> str:
    return " ".join(_TOKEN_RE.findall(str(answer or "").lower()))


def _normalize_url(url: str) -> str:
    url = url.strip().lower()
    url = re.sub(r"^https?://", "", url)
    url = re.sub(r"^www\.", "", url)
    return url.rstrip("/")


def _fact_key(question: Question) -> tuple[str, str] | None:
    """Identity of the backing fact: normalized source URL + answer.

    ``None`` when either half is missing — a partial key would collapse
    distinct facts (e.g. every question lacking a URL would share a key).
    Different facts from the same listicle URL keep distinct answers, so the
    pair stays discriminating.
    """
    url = getattr(question, "source_url", None)
    answer = _normalize_answer(question.correct_answer)
    if not url or not answer:
        return None
    return (_normalize_url(url), answer)


def _fact_tokens(question: Question) -> frozenset[str]:
    """Content tokens of question + answer, stopwords removed."""
    tokens = _TOKEN_RE.findall(
        f"{question.question} {question.correct_answer or ''}".lower()
    )
    return frozenset(t for t in tokens if t not in _STOPWORDS)


def _jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    intersection = len(a & b)
    union = len(a | b)
    if union == 0:
        return 0.0
    return intersection / union
