"""``review-export``, ``corrections`` and ``glossary`` (T16, DD3, locked decision 5).

The founder sees every critical (rejected) row, every flagged row (regional
flag or non-critical judge findings) and a seeded random sample of approvals
on the #154 rating web, in the ``publish_batch.py`` arm-file shape. Corrections
come back as append-only rows (never in-place edits — the MQM category
histogram is the glossary loop's input); the glossary files themselves are
reviewed git artefacts and are never written here.
"""

from __future__ import annotations

import json
import random
import uuid
from collections import Counter
from pathlib import Path
from typing import Any

from quiz_shared.database.pgvector_client import questions_table
from quiz_shared.database.translation_queries import question_translations_table
from sqlalchemy import literal_column, select, text
from sqlalchemy.ext.asyncio import AsyncEngine

from .verify import _ROW_COLUMNS


def select_for_review(
    rows: list[dict[str, Any]], *, sample: int, seed: int
) -> list[tuple[str, dict[str, Any]]]:
    """``(bucket, row)`` — every critical (rejected) row, every flagged row
    (regional flag or non-critical judge findings), plus a seeded random sample
    of the approved rest. Pure so the selection rule is testable."""
    out: list[tuple[str, dict[str, Any]]] = []
    rest: list[dict[str, Any]] = []
    for r in rows:
        v = r.get("verification") or {}
        if r["status"] == "rejected":
            out.append(("critical", r))
        elif (v.get("regional") or {}).get("flag") or (v.get("judge") or {}).get(
            "findings"
        ):
            out.append(("flagged", r))
        elif r["status"] == "approved":
            rest.append(r)
    rng = random.Random(seed)
    rng.shuffle(rest)
    out.extend(("sample", r) for r in rest[:sample])
    return out


def to_arm_item(bucket: str, row: dict[str, Any]) -> dict[str, Any]:
    """The ``publish_batch.py`` arm-file shape; the bucket rides ``topic`` so
    the founder sees why a row is on the page without unblinding anything."""
    return {
        "id": str(row["question_id"]),
        "question": row["question"],
        "possible_answers": row.get("possible_answers") or None,
        "correct_answer": row["correct_answer"],
        "alternative_answers": list(row.get("alternative_answers") or []),
        "explanation": row.get("explanation"),
        "topic": f"{row.get('src_category') or ''} · {bucket}",
        "difficulty": row.get("src_difficulty"),
        "source_url": row.get("src_source_url"),
    }


async def review_export(
    engine: AsyncEngine, language: str, *, sample: int, seed: int, out: Path
) -> Counter:
    tt, qt = question_translations_table, questions_table
    stmt = (
        select(
            *[tt.c[c].label(c) for c in _ROW_COLUMNS],
            literal_column("question_translations.verification").label("verification"),
            qt.c.category.label("src_category"),
            qt.c.difficulty.label("src_difficulty"),
            qt.c.source_url.label("src_source_url"),
        )
        .select_from(tt.join(qt, qt.c.id == tt.c.question_id))
        .where(tt.c.language == language, tt.c.status.in_(["approved", "rejected"]))
    )
    async with engine.connect() as conn:
        rows = [dict(r) for r in (await conn.execute(stmt)).mappings().all()]
    picked = select_for_review(rows, sample=sample, seed=seed)
    items = [to_arm_item(b, r) for b, r in picked]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
    sidecar = out.with_suffix(".reasons.json")
    sidecar.write_text(
        json.dumps(
            [
                {
                    "question_id": str(r["question_id"]),
                    "bucket": b,
                    "status": r["status"],
                    "verification": r.get("verification"),
                }
                for b, r in picked
            ],
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    return Counter(b for b, _ in picked)


# --------------------------------------------------------------------------
# corrections + glossary
# --------------------------------------------------------------------------

CORRECTION_FIELDS = ("question_id", "language", "field", "after", "category")


async def ingest_corrections(engine: AsyncEngine, items: list[dict[str, Any]]) -> int:
    """Append-only (DD3): never edits a translation in place."""
    tt = question_translations_table
    count = 0
    async with engine.begin() as conn:
        for item in items:
            missing = [f for f in CORRECTION_FIELDS if not item.get(f)]
            if missing:
                raise ValueError(f"correction missing {missing}: {item}")
            tid = (
                await conn.execute(
                    select(tt.c.id).where(
                        tt.c.question_id == uuid.UUID(str(item["question_id"])),
                        tt.c.language == item["language"],
                    )
                )
            ).scalar_one_or_none()
            if tid is None:
                raise ValueError(
                    f"no translation row for {item['question_id']}/{item['language']}"
                )
            await conn.execute(
                text(
                    "INSERT INTO question_translation_corrections "
                    "(id, translation_id, field, before, after, category, note, source) "
                    "VALUES (:id, :tid, :field, :before, :after, :category, :note, :source)"
                ),
                {
                    "id": uuid.uuid4(),
                    "tid": tid,
                    "field": item["field"],
                    "before": item.get("before"),
                    "after": item["after"],
                    "category": item["category"],
                    "note": item.get("note"),
                    "source": item.get("source") or "founder-review",
                },
            )
            count += 1
    return count


async def glossary_histogram(engine: AsyncEngine, language: str) -> Counter:
    """MQM category histogram of the founder's corrections — report only. The
    glossary files are reviewed git artefacts and are never written here."""
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text(
                    "SELECT c.category, count(*) FROM question_translation_corrections c "
                    "JOIN question_translations t ON t.id = c.translation_id "
                    "WHERE t.language = :lang GROUP BY c.category ORDER BY 2 DESC"
                ),
                {"lang": language},
            )
        ).all()
    return Counter({cat: n for cat, n in rows})
