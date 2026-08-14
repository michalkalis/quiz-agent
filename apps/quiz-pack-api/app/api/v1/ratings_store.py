"""Persistence + export helpers behind `/v1/ratings` (issue #154).

Split out of `ratings.py` so both files stay under the repo's ~300-line cap,
and so the upsert contract has one home: every writer (web page, in-app panel,
#156 backfill) goes through `upsert_rating` with its own `dedupe_key` and
inherits the same last-write-wins semantics.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Optional

from fastapi import HTTPException, status
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from ...db.models.rating import Rating, RatingBatch
from .ratings_schemas import SCORE_MAX, SCORE_MIN


async def upsert_rating(
    session: AsyncSession,
    *,
    dedupe_key: str,
    question_text: str,
    rater: str,
    score: float,
    source: str,
    reason: Optional[str] = None,
    batch_id: Optional[uuid.UUID] = None,
    blinded_qid: Optional[str] = None,
    question_id: Optional[str] = None,
    extra: Optional[dict[str, Any]] = None,
    scale_min: int = SCORE_MIN,
    scale_max: int = SCORE_MAX,
    rated_at: Optional[datetime] = None,
    refresh_identity: bool = False,
) -> tuple[uuid.UUID, datetime]:
    """Insert-or-update this rater's score, keyed by `dedupe_key`.

    ON CONFLICT rather than read-then-write: two tabs (or a debounced page and
    its retry) racing on the same key must converge on one row, and only the
    database can guarantee that.

    Only score/reason/timestamps are updated — identity columns are derived
    from the key, and `extra` is first-write-only so a later blank display name
    cannot erase the one already recorded.

    `scale_min`/`scale_max`/`rated_at` default to the live 1–10 form and "now";
    the #156 backfill passes a historical round's own scale and date so the
    export can normalise instead of rewriting raw scores. `refresh_identity`
    additionally lets a file-driven re-import correct the snapshot columns —
    safe there because the source file, not a rater's form, is the truth.
    """
    now = datetime.now(timezone.utc)
    when = rated_at or now
    amount = Decimal(str(score))
    updates: dict[str, Any] = {
        "score": amount,
        "reason": reason,
        "rated_at": when,
        "updated_at": now,
    }
    if refresh_identity:
        updates.update(
            question_text=question_text,
            question_id=question_id,
            blinded_qid=blinded_qid,
            scale_min=scale_min,
            scale_max=scale_max,
            extra=extra,
        )
    stmt = (
        pg_insert(Rating)
        .values(
            id=uuid.uuid4(),
            dedupe_key=dedupe_key,
            batch_id=batch_id,
            blinded_qid=blinded_qid,
            question_id=question_id,
            question_text=question_text,
            rater=rater,
            score=amount,
            scale_min=scale_min,
            scale_max=scale_max,
            reason=reason,
            source=source,
            rated_at=when,
            extra=extra,
            created_at=now,
            updated_at=now,
        )
        .on_conflict_do_update(index_elements=["dedupe_key"], set_=updates)
        .returning(Rating.id, Rating.rated_at)
    )
    row = (await session.execute(stmt)).one()
    await session.commit()
    return row[0], row[1]


async def load_batch(session: AsyncSession, batch_id: str) -> RatingBatch:
    """Fetch a batch or 404 — a malformed UUID is also 404, never 422.

    Distinguishing "well-formed but unknown" from "malformed" would help a
    caller probe the id space, and the id is the only credential these routes
    have.
    """
    try:
        parsed = uuid.UUID(batch_id)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Unknown rating batch"
        ) from None
    batch = await session.get(RatingBatch, parsed)
    if batch is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Unknown rating batch"
        )
    return batch


def original_question_id(batch: RatingBatch, qid: str) -> Optional[str]:
    """Unblind one qid from the server-only mapping (never sent to the rater)."""
    entry = (batch.mapping or {}).get(qid)
    if not isinstance(entry, dict):
        return None
    original = entry.get("original_id")
    return str(original)[:64] if original else None


def normalize_to_10(score: Decimal, scale_min: int, scale_max: int) -> float:
    """Linear map of a raw score onto 1–10 so mixed-scale rounds compare.

    The raw score is never rewritten — a historical 1–5 round keeps its bounds
    on the row and gains this derived column only in the export.
    """
    span = scale_max - scale_min
    if span <= 0:  # blocked by ck_ratings_scale_range; belt and braces
        return float(score)
    return round(1 + (float(score) - scale_min) * 9 / span, 4)


def export_line(r: Rating) -> str:
    """One JSONL row: every column plus the normalised score."""
    row = {
        "id": str(r.id),
        "dedupe_key": r.dedupe_key,
        "batch_id": str(r.batch_id) if r.batch_id else None,
        "blinded_qid": r.blinded_qid,
        "question_id": r.question_id,
        "question_text": r.question_text,
        "rater": r.rater,
        "score": float(r.score),
        "scale_min": r.scale_min,
        "scale_max": r.scale_max,
        "score_normalized_10": normalize_to_10(r.score, r.scale_min, r.scale_max),
        "reason": r.reason,
        "source": r.source,
        "rated_at": r.rated_at.isoformat(),
        "extra": r.extra,
        "created_at": r.created_at.isoformat(),
        "updated_at": r.updated_at.isoformat(),
    }
    return json.dumps(row, ensure_ascii=False) + "\n"
