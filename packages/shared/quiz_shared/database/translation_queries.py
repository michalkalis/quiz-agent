"""Serve-side reads and staleness demotion over `question_translations`
(#168 — batch translation pipeline SK/CS, DD3/DD5).

Kept out of `pgvector_client.py` for the same reason the questions mirror lives
there: that module is already large, and these are a distinct table's queries.

**Schema duplication is deliberate**, exactly as in `pgvector_client`: the ORM
model lives in `apps/quiz-pack-api/app/db/models/translation.py`; importing it
here would invert the dependency direction (shared -> app). This declares a
minimal SQLAlchemy Core `Table` mirroring only the columns the serve path and
the demotion touch. The authoritative schema is alembic's.
"""

from __future__ import annotations

import uuid
from typing import Any, Dict, Iterable, List, Optional, Sequence

from sqlalchemy import (
    Column,
    DateTime,
    String,
    Table,
    Text,
    func,
    select,
    update,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.ext.asyncio import AsyncSession

from ._schema import metadata

question_translations_table = Table(
    "question_translations",
    metadata,
    Column("id", PGUUID(as_uuid=True), primary_key=True),
    Column("question_id", PGUUID(as_uuid=True), nullable=False),
    Column("language", String(16), nullable=False),
    Column("status", String(16), nullable=False),
    Column("question", Text, nullable=False),
    Column("possible_answers", JSONB, nullable=True),
    Column("explanation", Text, nullable=True),
    Column("headline_answer", Text, nullable=True),
    Column("correct_answer", Text, nullable=False),
    Column("correct_answer_key", String(8), nullable=True),
    Column("alternative_answers", JSONB, nullable=False),
    Column("source_hash", String(64), nullable=False),
    Column("updated_at", DateTime(timezone=True), nullable=False),
)

# The serve payload `serializers.py` reads back. `status` and `source_hash` are
# not part of it: the caller already asked for approved rows, and the hash is
# the write path's business.
_SERVE_COLUMNS = (
    "question_id",
    "language",
    "question",
    "possible_answers",
    "explanation",
    "headline_answer",
    "correct_answer",
    "correct_answer_key",
    "alternative_answers",
)

# One `IN (...)` per chunk. A retrieval asks for at most ~50 candidate ids, so
# this only bounds pathological callers (a coverage sweep over the corpus).
_ID_CHUNK = 500

__all__ = [
    "question_translations_table",
    "fetch_approved_translations",
    "demote_stale_translations",
]


def _chunks(items: Sequence[Any], size: int) -> Iterable[Sequence[Any]]:
    for start in range(0, len(items), size):
        yield items[start : start + size]


async def fetch_approved_translations(
    session: AsyncSession,
    question_ids: Sequence[uuid.UUID],
    language: str,
) -> Dict[str, Dict[str, Any]]:
    """Approved translations for these questions, keyed by question id (str).

    A missing key means "no approved translation" — the retriever drops that
    candidate rather than falling back to English (locked decision 2).
    """
    if not question_ids:
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    columns = [question_translations_table.c[name] for name in _SERVE_COLUMNS]
    for chunk in _chunks(list(question_ids), _ID_CHUNK):
        stmt = select(*columns).where(
            question_translations_table.c.question_id.in_(list(chunk)),
            question_translations_table.c.language == language,
            question_translations_table.c.status == "approved",
        )
        result = await session.execute(stmt)
        for row in result.mappings().all():
            record = dict(row)
            record["question_id"] = str(record["question_id"])
            record["alternative_answers"] = list(record["alternative_answers"] or [])
            out[record["question_id"]] = record
    return out


async def demote_stale_translations(
    session: AsyncSession,
    questions_table: Table,
    question_id: Optional[uuid.UUID],
    source_hash: str,
) -> List[str]:
    """Mark every approved translation of `question_id` whose stored
    `source_hash` no longer matches the English source as `stale`, and drop its
    language from `questions.approved_languages`.

    Returns the demoted languages. Runs on the caller's session so it commits in
    the SAME transaction as the source edit: a demotion that could be lost while
    the edit lands would leave a translation of text that no longer exists
    serving, which is the whole failure DD3 exists to close.
    """
    if question_id is None:
        return []
    demoted = (
        (
            await session.execute(
                update(question_translations_table)
                .where(
                    question_translations_table.c.question_id == question_id,
                    question_translations_table.c.status == "approved",
                    question_translations_table.c.source_hash != source_hash,
                )
                .values(status="stale", updated_at=func.now())
                .returning(question_translations_table.c.language)
            )
        )
        .scalars()
        .all()
    )
    for language in demoted:
        await session.execute(
            update(questions_table)
            .where(questions_table.c.id == question_id)
            .values(
                approved_languages=func.array_remove(
                    questions_table.c.approved_languages, language
                )
            )
        )
    return list(demoted)
