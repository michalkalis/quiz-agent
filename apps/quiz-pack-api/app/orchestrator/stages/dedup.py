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
- **QA cosine similarity ≥ 0.90 (#170 D2, ``qa_embedding=True`` only)** —
  closes exactly that gap: the candidate's question+answer text is compared
  against the corpus's ``embedding_qa`` column, where same-fact pairs sit
  higher than on question-only vectors. Default OFF; when ON the stage first
  refuses to run over a corpus whose QA backfill is incomplete, because a
  half-covered column would silently lose recall.
- **Gray-zone judge (#170 D7, ``grayzone_judge`` injected only)** — a
  candidate whose nearest corpus match sits in ``[0.70, cosine threshold)``
  gets one pairwise "same fact?" model verdict (``GrayZoneJudge``); "yes"
  drops under its own reason, everything else falls back to today's
  below-threshold pass. Bounded per run, warns when the budget is gone.

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
from collections.abc import Iterable
from pathlib import Path
from typing import Any, Protocol

from quiz_shared.database.pgvector_client import DEFAULT_QA_COSINE_THRESHOLD
from quiz_shared.models.question import Question

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.orchestrator.stages.grayzone_judge import GRAYZONE_LOW, GrayZoneJudge
from app.orchestrator.stages.strictness import NO_STRICTNESS, Strictness

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
    ["a", "an", "the", "of", "in", "on", "at", "to", "for", "is", "are", "was", "were", "be", "been", "do", "does", "did", "doing", "what", "which", "who", "whom", "whose", "how", "when", "where", "why", "your", "you", "it", "its", "not", "no", "but", "and", "or", "as", "by", "with", "from", "this", "that", "these", "those", "there", "here", "have", "has", "had", "can", "could", "will", "would", "may", "might", "most", "more"]
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


class AsyncQaDuplicateFinder(Protocol):
    """#170 D2 — the question+answer branch of the corpus lookup.

    Only required when ``qa_embedding=True``; the customer-pack worker never
    turns it on, so the plain ``AsyncDuplicateFinder`` stays sufficient there.
    """

    async def find_duplicates_qa(
        self,
        question_text: str,
        correct_answer: Any,
        possible_answers: dict[str, str] | None = None,
        threshold: float = DEFAULT_QA_COSINE_THRESHOLD,
    ) -> list[tuple[Question, float]]: ...

    async def count_qa_backfill_gap(self) -> int: ...

    async def count_missing_language(self) -> int: ...


QA_BACKFILL_INSTRUCTION = (
    "run `python scripts/backfill_embedding_qa.py --execute` (apps/quiz-pack-api) "
    "over this database before enabling DEDUP_QA_EMBEDDING"
)


class AsyncAnswerCounter(Protocol):
    """#170 D6 — how many *live corpus* rows already carry this normalized answer.

    Scope is the store's: ``pack_id IS NULL`` (customer packs never count,
    locked 3) and live review states only (gate F1 R2). The stage adds the
    answers it kept in the current batch on top.
    """

    async def count_answer_key(
        self, language: str, category: str, answer_key: str
    ) -> int: ...


class DedupStage:
    """Drops near-duplicate questions via cosine + Jaccard checks.

    #170 D5/D6: ``strictness`` and ``answer_counter`` are constructor
    parameters with defaults that reproduce today's behaviour exactly. Only
    ``scripts/generate_pack.py`` (corpus runs) ever fills them; the customer
    pack worker never does, so a mis-set prod secret cannot change a pack.
    """

    name = "dedup"

    def __init__(
        self,
        question_store: AsyncDuplicateFinder,
        gold_standard_path: str | Path | None,
        cosine_threshold: float = DEFAULT_COSINE_THRESHOLD,
        jaccard_threshold: float = DEFAULT_JACCARD_THRESHOLD,
        in_batch_threshold: float = DEFAULT_IN_BATCH_JACCARD_THRESHOLD,
        fact_jaccard_threshold: float = DEFAULT_FACT_JACCARD_THRESHOLD,
        strictness: Strictness | None = None,
        answer_counter: AsyncAnswerCounter | None = None,
        qa_embedding: bool = False,
        qa_cosine_threshold: float = DEFAULT_QA_COSINE_THRESHOLD,
        grayzone_judge: GrayZoneJudge | None = None,
    ) -> None:
        self._store = question_store
        self._gold_standard_path = (
            Path(gold_standard_path) if gold_standard_path is not None else None
        )
        self._cosine_threshold = cosine_threshold
        self._jaccard_threshold = jaccard_threshold
        self._in_batch_threshold = in_batch_threshold
        self._fact_jaccard_threshold = fact_jaccard_threshold
        self._strictness = strictness if strictness is not None else NO_STRICTNESS
        self._answer_counter = answer_counter
        if self._strictness.answer_cap and answer_counter is None:
            raise ValueError(
                "DedupStage: answer_cap is ON but no answer_counter was injected — "
                "the cap would silently count only the current batch"
            )
        self._qa_embedding = qa_embedding
        self._qa_cosine_threshold = qa_cosine_threshold
        if qa_embedding and not hasattr(question_store, "find_duplicates_qa"):
            raise ValueError(
                "DedupStage: qa_embedding is ON but the question store has no "
                "find_duplicates_qa — the QA branch would silently never run"
            )
        self._grayzone_judge = grayzone_judge
        self._gold_tokens: list[frozenset[str]] | None = None
        # Per-candidate trace of the last `run` (id, kept, reason, nearest
        # corpus pair + score). An attribute, not `StageResult.info`, so the
        # SSE payload of the customer path is untouched; the replay harness
        # (170.14b) and Session K's diff read it after the run.
        self.last_decisions: list[dict[str, Any]] = []

    # Per-candidate thresholds (D6): resolved by the candidate's category at
    # check time; a category without a profile gets the constructor scalar.
    def _cosine_for(self, q: Question) -> float:
        return self._strictness.cosine_for(q.category, self._cosine_threshold)

    def _in_batch_for(self, q: Question) -> float:
        return self._strictness.in_batch_for(q.category, self._in_batch_threshold)

    def _fact_for(self, q: Question) -> float:
        return self._strictness.fact_for(q.category, self._fact_jaccard_threshold)

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"kept": 0, "dropped": 0}, cost_cents=0)

        gold_tokens = self._load_gold_tokens()
        if self._qa_embedding:
            await self._assert_qa_corpus_ready()

        kept: list[Question] = []
        kept_tokens: list[frozenset[str]] = []
        kept_in_batch: list[float] = []  # each kept row's own in-batch threshold
        kept_fact_keys: set[tuple[str, str]] = set()
        kept_fact_tokens: list[frozenset[str]] = []
        kept_answer_counts: dict[tuple[str, str, str], int] = {}
        dropped = 0
        fact_dropped = 0
        cap_dropped = 0
        decisions: list[dict[str, Any]] = []
        reasons = {
            "cosine": 0,
            "cosine_qa": 0,
            "grayzone_judge": 0,
            "jaccard": 0,
            "in_batch": 0,
            "fact_key": 0,
            "fact_content": 0,
        }
        for q in ctx.questions:
            verdict, pair = await self._cosine_verdict(q, self._cosine_for(q))
            if verdict is not None:
                dropped += 1
                reasons[verdict] += 1
                decisions.append(_decision(q, verdict, pair))
                continue
            if self._qa_embedding:
                qa_pair = await self._qa_match(q)
                if qa_pair is not None:
                    dropped += 1
                    reasons["cosine_qa"] += 1
                    decisions.append(_decision(q, "cosine_qa", qa_pair))
                    continue
            if self._is_jaccard_duplicate(q, gold_tokens):
                dropped += 1
                reasons["jaccard"] += 1
                decisions.append(_decision(q, "jaccard", None))
                continue
            # In-batch check (#72, 2026-07-10): the corpus lookup cannot see
            # questions from the same not-yet-persisted batch, so without this
            # a batch can carry near-verbatim repeats of itself (the June-18
            # audit batch had the same bridge question 3×). First occurrence
            # wins; later near-copies drop. #170 D6: a pairwise check between
            # two categories uses the STRICTER (lower) of the two thresholds,
            # so relaxing one category never loosens the other.
            q_tokens = _tokenize(q.question)
            q_in_batch = self._in_batch_for(q)
            if q_tokens and any(
                _jaccard(q_tokens, k) >= min(q_in_batch, k_thr)
                for k, k_thr in zip(kept_tokens, kept_in_batch)
            ):
                dropped += 1
                reasons["in_batch"] += 1
                decisions.append(_decision(q, "in_batch", None))
                continue
            # Same-fact reuse (#153 Phase 0.1): one fact backs one question
            # per pack, across formats and top-up rounds (top-up merges
            # survivors before this stage re-runs, so earlier rounds are in
            # `kept_*` here). First occurrence wins. The exact fact-key match
            # stays global (D6); only the content threshold is per category.
            fact_key = _fact_key(q)
            fact_tokens = _fact_tokens(q)
            if fact_key is not None and fact_key in kept_fact_keys:
                fact_dropped += 1
                reasons["fact_key"] += 1
                logger.warning(
                    "DedupStage same-fact dropped id=%s (fact key reuse "
                    "url=%s answer=%s)",
                    q.id,
                    fact_key[0],
                    fact_key[1],
                )
                decisions.append(_decision(q, "fact_key", None))
                continue
            fact_threshold = self._fact_for(q)
            if fact_tokens and any(
                _jaccard(fact_tokens, k) >= fact_threshold for k in kept_fact_tokens
            ):
                fact_dropped += 1
                reasons["fact_content"] += 1
                logger.warning(
                    "DedupStage same-fact dropped id=%s (content overlap "
                    ">= %.2f with an earlier batchmate)",
                    q.id,
                    fact_threshold,
                )
                decisions.append(_decision(q, "fact_content", None))
                continue
            # #170 D6 — per-category repeated-answer cap (ANSWER_CAP). Not a
            # quality gate but a waste brake (locked 2): the candidate simply
            # drops, nothing is regenerated. Counted over live corpus rows
            # (store scope) plus what this batch already kept.
            if self._strictness.answer_cap and self._answer_counter is not None:
                cell = (
                    (q.language or "en"),
                    (q.category or ""),
                    _normalize_answer(q.correct_answer),
                )
                if cell[2]:
                    if cell not in kept_answer_counts:
                        kept_answer_counts[
                            cell
                        ] = await self._answer_counter.count_answer_key(*cell)
                    if kept_answer_counts[cell] >= self._strictness.cap_for(q.category):
                        cap_dropped += 1
                        logger.warning(
                            "DedupStage answer-cap dropped id=%s (%s/%s answer=%r "
                            "already at %d)",
                            q.id,
                            cell[0],
                            cell[1],
                            cell[2],
                            kept_answer_counts[cell],
                        )
                        decisions.append(_decision(q, "answer_cap", None))
                        continue
                    kept_answer_counts[cell] += 1
            decisions.append(_decision(q, None, pair))
            kept.append(q)
            kept_tokens.append(q_tokens)
            kept_in_batch.append(q_in_batch)
            kept_fact_tokens.append(fact_tokens)
            if fact_key is not None:
                kept_fact_keys.add(fact_key)

        ctx.questions = kept
        self.last_decisions = decisions
        judge = self._grayzone_judge
        return StageResult(
            info={
                "kept": len(kept),
                "dropped": dropped + fact_dropped + cap_dropped,
                "fact_dropped": fact_dropped,
                # #170: own counter so cap drops never blend into cosine drops
                # in the quality-guard metrics; `drop_reasons` is the full split.
                "answer_cap": cap_dropped,
                "drop_reasons": {**reasons, "answer_cap": cap_dropped},
                # #170 D7 — budget accounting; zeros when no judge is injected.
                "grayzone_judge_calls": judge.calls if judge else 0,
                "grayzone_judge_skipped": judge.skipped if judge else 0,
            },
            cost_cents=0,
        )

    async def _cosine_verdict(
        self, question: Question, threshold: float
    ) -> tuple[str | None, tuple[Question, float] | None]:
        """Question-only corpus check → (drop reason or None, nearest pair).

        Without a gray-zone judge this is exactly the legacy
        ``_is_cosine_duplicate`` call. With one, the store is asked down to
        ``GRAYZONE_LOW`` so the nearest below-threshold match is visible; only
        the single nearest gray-zone pair is judged (one call per candidate).
        """
        if self._grayzone_judge is None:
            is_dup = await self._is_cosine_duplicate(question, threshold)
            return ("cosine" if is_dup else None), None
        try:
            matches = await self._store.find_duplicates(
                question.question, threshold=GRAYZONE_LOW
            )
        except Exception:  # noqa: BLE001 — mirrors the legacy store fail-safe
            # Same fail-safe as the legacy branch: a store outage never drops.
            return None, None
        others = sorted(
            ((m, s) for m, s in matches if m.id != question.id),
            key=lambda pair: pair[1],
            reverse=True,
        )
        if not others:
            return None, None
        nearest = others[0]
        if nearest[1] >= threshold:
            return "cosine", nearest
        if nearest[1] >= GRAYZONE_LOW:
            same = await self._grayzone_judge.same_fact(
                question, nearest[0], nearest[1]
            )
            if same:
                logger.info(
                    "DedupStage gray-zone judge dropped id=%s (%.3f vs corpus id=%s)",
                    question.id,
                    nearest[1],
                    nearest[0].id,
                )
                return "grayzone_judge", nearest
        return None, nearest

    async def _is_cosine_duplicate(
        self, question: Question, threshold: float | None = None
    ) -> bool:
        if threshold is None:
            threshold = self._cosine_threshold
        try:
            duplicates = await self._store.find_duplicates(
                question.question, threshold=threshold
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

    async def _qa_match(self, question: Question) -> tuple[Question, float] | None:
        """#170 D2 — same fact, disjoint wording: the nearest non-self QA match
        at or above the QA threshold, or ``None``. Unlike the question-only
        branch this does NOT swallow store errors: the flag is only ever on in
        corpus CLI runs, where a failing query must stop the run rather than
        quietly pass every candidate."""
        duplicates = await self._store.find_duplicates_qa(  # type: ignore[attr-defined]
            question.question,
            question.correct_answer,
            question.possible_answers,
            threshold=self._qa_cosine_threshold,
        )
        for match, score in duplicates:
            if match.id != question.id:
                logger.info(
                    "DedupStage cosine-qa dropped id=%s (%.3f vs corpus id=%s)",
                    question.id,
                    score,
                    match.id,
                )
                return match, score
        return None

    async def _assert_qa_corpus_ready(self) -> None:
        """Fail loud on an incomplete QA backfill; warn on NULL languages."""
        gap = await self._store.count_qa_backfill_gap()  # type: ignore[attr-defined]
        if gap:
            raise RuntimeError(
                f"DedupStage: qa_embedding is ON but {gap} live corpus row(s) "
                f"have an embedding and no embedding_qa — {QA_BACKFILL_INSTRUCTION}"
            )
        missing_language = await self._store.count_missing_language()  # type: ignore[attr-defined]
        if missing_language:
            logger.warning(
                "DedupStage: %d live corpus row(s) have language IS NULL — "
                "the free `backfill_embedding_qa.py --answer-key-only` pass sets them to 'en'",
                missing_language,
            )

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


def _decision(
    question: Question, reason: str | None, pair: tuple[Question, float] | None
) -> dict[str, Any]:
    """One row of ``DedupStage.last_decisions`` — JSON-serialisable."""
    return {
        "id": question.id,
        "question": question.question,
        "kept": reason is None,
        "reason": reason,
        "match_id": pair[0].id if pair else None,
        "match_question": pair[0].question if pair else None,
        "score": round(pair[1], 4) if pair else None,
    }


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
