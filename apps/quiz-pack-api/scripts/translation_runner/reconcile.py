"""``reconcile`` (T17, DD1): the two drift-control legs.

Staleness first — recompute each approved row's ``source_hash`` from the
CURRENT English text and demote on mismatch in one transaction (``stale`` +
language removed from ``approved_languages``). Then consistency — the derived
column must equal "has an approved row"; mismatches are reported and, with
``fix``, rewritten. Any finding is a non-zero exit for the caller.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from quiz_shared.database.pgvector_client import questions_table
from quiz_shared.database.translation_queries import question_translations_table
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncEngine

from .workset import SOURCE_COLUMNS, row_source_hash


@dataclass
class ReconcileFindings:
    consistency: list[dict[str, Any]] = field(default_factory=list)
    stale: list[dict[str, Any]] = field(default_factory=list)

    @property
    def clean(self) -> bool:
        return not self.consistency and not self.stale


async def reconcile(
    engine: AsyncEngine, language: str, *, fix: bool = False
) -> ReconcileFindings:
    """Two legs (DD1). Staleness demotes in one transaction; the consistency
    leg reports (and with ``fix`` rewrites the derived column)."""
    tt, qt = question_translations_table, questions_table
    findings = ReconcileFindings()

    # Leg 2 first: staleness — recompute each approved row's hash from the
    # CURRENT English text and demote on mismatch.
    stmt = (
        select(
            tt.c.id.label("tid"),
            tt.c.question_id,
            tt.c.source_hash,
            *[qt.c[c].label(c) for c in SOURCE_COLUMNS if c != "id"],
        )
        .select_from(tt.join(qt, qt.c.id == tt.c.question_id))
        .where(tt.c.language == language, tt.c.status == "approved")
    )
    async with engine.connect() as conn:
        approved = [dict(r) for r in (await conn.execute(stmt)).mappings().all()]
    for r in approved:
        current = row_source_hash(r)
        if current == r["source_hash"]:
            continue
        async with engine.begin() as conn:
            await conn.execute(
                update(tt)
                .where(tt.c.id == r["tid"])
                .values(status="stale", updated_at=func.now())
            )
            await conn.execute(
                update(qt)
                .where(qt.c.id == r["question_id"])
                .values(
                    approved_languages=func.array_remove(
                        qt.c.approved_languages, language
                    )
                )
            )
        findings.stale.append(
            {
                "qid": str(r["question_id"]),
                "language": language,
                "old_hash": r["source_hash"],
                "new_hash": current,
            }
        )

    # Leg 1: consistency — column ⇔ table, after the demotions above.
    async with engine.connect() as conn:
        approved_ids = {
            str(x)
            for x in (
                await conn.execute(
                    select(tt.c.question_id).where(
                        tt.c.language == language, tt.c.status == "approved"
                    )
                )
            ).scalars()
        }
        flagged = {
            str(x)
            for x in (
                await conn.execute(
                    select(qt.c.id).where(qt.c.approved_languages.contains([language]))
                )
            ).scalars()
        }
    for qid in sorted(approved_ids - flagged):
        findings.consistency.append(
            {"qid": qid, "issue": "approved row, language missing from column"}
        )
    for qid in sorted(flagged - approved_ids):
        findings.consistency.append(
            {"qid": qid, "issue": "language in column, no approved row"}
        )
    if fix and findings.consistency:
        async with engine.begin() as conn:
            for qid in approved_ids - flagged:
                await conn.execute(
                    update(qt)
                    .where(qt.c.id == uuid.UUID(qid))
                    .values(
                        approved_languages=func.array_append(
                            qt.c.approved_languages, language
                        )
                    )
                )
            for qid in flagged - approved_ids:
                await conn.execute(
                    update(qt)
                    .where(qt.c.id == uuid.UUID(qid))
                    .values(
                        approved_languages=func.array_remove(
                            qt.c.approved_languages, language
                        )
                    )
                )
    return findings
