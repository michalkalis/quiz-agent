"""Work-set selection + durable job state for ``translate_corpus.py`` (T15).

A *source row* is an English corpus question that can be served in a quiz:
no ``pack_id`` (DD15 — packs are never translated), not ``language_dependent``
(#128 filter), and in one of the review channels the caller asked for. The
default channel set is ``approved`` + ``pending_review`` (founder 2026-09-10:
"translate all English questions"); the coverage bars in ``report`` stay
approved-only (DD4) regardless of what was translated.

A source row is *work* for a language when it has no translation row yet, or
its row is ``stale`` (DD1: the English text changed after approval). ``pending``
/ ``approved`` / ``rejected`` rows are never re-translated implicitly.

Job state lives in one JSONL per job (``data/translation_jobs/<job_id>.jsonl``):
``translation`` lines are the resume unit (``done_qids``), ``ingested`` lines
mark what reached the DB, so a killed run re-enters without duplicating.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from quiz_shared.database.pgvector_client import questions_table
from quiz_shared.database.translation_queries import question_translations_table
from quiz_shared.models.question import Question
from quiz_shared.utils.source_hash import TRANSLATED_SOURCE_FIELDS, source_hash_for
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine

DEFAULT_REVIEW_STATUSES: tuple[str, ...] = ("approved", "pending_review")
SUPPORTED_LANGUAGES: tuple[str, ...] = ("sk", "cs")
JOBS_DIR = Path("data/translation_jobs")

#: Columns the runner reads off a source row: the translated fields, what the
#: gate needs to build a ``Question``, and what the rating export shows.
SOURCE_COLUMNS: tuple[str, ...] = (
    "id",
    "question",
    "type",
    "possible_answers",
    "correct_answer",
    "headline_answer",
    "alternative_answers",
    "explanation",
    "topic",
    "category",
    "difficulty",
    "tags",
    "language_dependent",
    "language",
    "source",
    "source_url",
    "review_status",
    "created_at",
    "approved_languages",
)


def _jsonable(value: Any) -> Any:
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    return value


async def fetch_source_rows(
    engine: AsyncEngine, review_statuses: Sequence[str] = DEFAULT_REVIEW_STATUSES
) -> list[dict[str, Any]]:
    """Serving-eligible English rows in the given review channels."""
    t = questions_table
    stmt = (
        select(*[t.c[c] for c in SOURCE_COLUMNS])
        .where(
            t.c.pack_id.is_(None),
            t.c.language_dependent.is_(False),
            t.c.review_status.in_(list(review_statuses)),
            (t.c.language.is_(None)) | (t.c.language == "en"),
        )
        .order_by(t.c.created_at, t.c.id)
    )
    async with engine.connect() as conn:
        rows = (await conn.execute(stmt)).mappings().all()
    return [_jsonable(dict(r)) for r in rows]


async def fetch_translation_states(
    engine: AsyncEngine, language: str
) -> dict[str, str]:
    """``question_id -> status`` for every translation row in ``language``."""
    t = question_translations_table
    stmt = select(t.c.question_id, t.c.status).where(t.c.language == language)
    async with engine.connect() as conn:
        rows = (await conn.execute(stmt)).all()
    return {str(qid): status for qid, status in rows}


def work_set(
    rows: Iterable[dict[str, Any]], states: dict[str, str]
) -> list[dict[str, Any]]:
    """Rows with no translation yet, or whose translation went ``stale``."""
    return [r for r in rows if states.get(str(r["id"])) in (None, "stale")]


def source_question(row: dict[str, Any]) -> Question:
    """The shared ``Question`` the gate stages take, from a runner source row.

    Built directly rather than through the store's row mapper: the gate reads
    text fields only, and the mapper demands every column of the table
    (embeddings, usage counters) that the runner has no reason to select.
    """
    return Question(
        id=str(row["id"]),
        question=row["question"],
        type=row.get("type") or "text",
        possible_answers=row.get("possible_answers"),
        correct_answer=row["correct_answer"],
        headline_answer=row.get("headline_answer"),
        alternative_answers=list(row.get("alternative_answers") or []),
        explanation=row.get("explanation"),
        topic=row.get("topic") or "",
        category=row.get("category") or "",
        difficulty=row.get("difficulty") or "medium",
        tags=list(row.get("tags") or []),
        language_dependent=bool(row.get("language_dependent")),
        language=row.get("language"),
        source=row.get("source") or "generated",
        source_url=row.get("source_url"),
        review_status=row.get("review_status") or "pending_review",
        created_at=row.get("created_at") or datetime.now(UTC),
    )


def correct_answer_key(row: dict[str, Any]) -> str | None:
    """MCQ option key for the source row, resolved while both sides are still
    English (mirrors ``serializers.correct_option_key``). ``None`` for open
    questions and for MCQ rows whose stored answer matches no option."""
    options = row.get("possible_answers") or {}
    if not options:
        return None
    answer = row.get("correct_answer")
    if isinstance(answer, list):
        answer = answer[0] if answer else ""
    answer = str(answer or "").strip()
    lowered = answer.casefold()
    for key in options:
        if str(key).casefold() == lowered:
            return str(key)
    for key, text in options.items():
        if str(text or "").strip().casefold() == lowered:
            return str(key)
    return None


def source_fields(row: dict[str, Any]) -> dict[str, Any]:
    """Exactly the translated fields — what the prompt sees and the hash covers."""
    return {name: row.get(name) for name in TRANSLATED_SOURCE_FIELDS}


def row_source_hash(row: dict[str, Any]) -> str:
    return source_hash_for(source_fields(row))


# --------------------------------------------------------------------------
# Job JSONL
# --------------------------------------------------------------------------


class Job:
    """Append-only JSONL log of one submit/ingest job."""

    def __init__(self, job_id: str, jobs_dir: Path = JOBS_DIR):
        self.id = job_id
        self.path = jobs_dir / f"{job_id}.jsonl"

    @staticmethod
    def new_id(language: str) -> str:
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
        return f"{language}-{stamp}-{uuid.uuid4().hex[:6]}"

    def append(self, record: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(_jsonable(record), ensure_ascii=False) + "\n")

    def records(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        out = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                out.append(json.loads(line))
        return out

    def meta(self) -> dict[str, Any] | None:
        return next((r for r in self.records() if r.get("kind") == "meta"), None)

    def done_qids(self, kind: str = "translation") -> set[str]:
        return {str(r["qid"]) for r in self.records() if r.get("kind") == kind}

    def translations(self) -> list[dict[str, Any]]:
        return [r for r in self.records() if r.get("kind") == "translation"]

    def cost_usd(self) -> float | None:
        """Job-level spend: the sum of ``cost`` lines, ``None`` if any was
        unavailable (DD9 — never a fake 0)."""
        costs = [r for r in self.records() if r.get("kind") == "cost"]
        if not costs:
            return None
        if any(c.get("usd") is None for c in costs):
            return None
        return float(sum(float(c["usd"]) for c in costs))
