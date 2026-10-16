"""One-way copy of the old volume state into Postgres (#207.20 cutover).

Until the volume is removed (resilience design step 6), a boot with
``LEGACY_STATE_DIR`` set copies what the previous release kept in SQLite on
``/data`` — live quiz sessions, ratings and the paid translation cache — into
the shared tables. Idempotent: rows that already exist are never overwritten
(Postgres wins), expired sessions are skipped, so running it on every boot is
harmless. Delete this module together with the volume.
"""

from __future__ import annotations

import logging
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from quiz_shared.models.session import QuizSession
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from .db.models import QuestionRatingRow, QuizSessionRow, TranslationCacheRow
from .translation.store import source_hash

logger = logging.getLogger(__name__)


def _rows(db_path: Path, sql: str) -> list[tuple]:
    if not db_path.exists():
        return []
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return con.execute(sql).fetchall()
    except sqlite3.Error as e:
        logger.warning("Legacy import: cannot read %s: %s", db_path, e)
        return []
    finally:
        con.close()


def _aware(value) -> datetime:
    if isinstance(value, str):
        value = datetime.fromisoformat(value)
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


async def import_legacy_state(
    state_dir: str, sm: async_sessionmaker[AsyncSession]
) -> dict[str, int]:
    root = Path(state_dir)
    now = datetime.now(timezone.utc)
    sessions, ratings, translations = [], [], []

    for session_id, data_json in _rows(
        root / "ratings.db",
        "SELECT session_id, data_json FROM quiz_sessions WHERE is_active = 1",
    ):
        try:
            session = QuizSession.model_validate_json(data_json)
        except ValueError:
            continue
        if session.expires_at < now:
            continue
        sessions.append(
            {
                "session_id": session_id,
                "data_json": data_json,
                "version": 1,
                "is_active": True,
                "expires_at": session.expires_at,
                "created_at": session.created_at,
                "updated_at": now,
            }
        )

    for row in _rows(
        root / "ratings.db",
        "SELECT id, question_id, session_id, user_id, rating, feedback, was_correct,"
        " user_answer, difficulty_at_time, created_at FROM question_ratings",
    ):
        ratings.append(
            dict(
                zip(
                    (
                        "id",
                        "question_id",
                        "session_id",
                        "user_id",
                        "rating",
                        "feedback",
                        "was_correct",
                        "user_answer",
                        "difficulty_at_time",
                        "created_at",
                    ),
                    row,
                )
            )
        )
        ratings[-1]["was_correct"] = None if row[6] is None else bool(row[6])
        ratings[-1]["created_at"] = _aware(row[9]) if row[9] else now

    for kind, text, lang, version, translated in _rows(
        root / "translations.db",
        "SELECT kind, source_text, target_language, version, translated_text"
        " FROM translations",
    ):
        translations.append(
            {
                "kind": kind,
                "source_hash": source_hash(text),
                "target_language": lang,
                "version": version,
                "source_text": text,
                "translated_text": translated,
            }
        )

    counts = {}
    async with sm() as db:
        for name, model, rows in (
            ("sessions", QuizSessionRow, sessions),
            ("ratings", QuestionRatingRow, ratings),
            ("translations", TranslationCacheRow, translations),
        ):
            inserted = 0
            for i in range(0, len(rows), 500):
                result = await db.execute(
                    pg_insert(model).values(rows[i : i + 500]).on_conflict_do_nothing()
                )
                inserted += result.rowcount or 0
            counts[name] = inserted
        await db.commit()
    logger.info("Legacy volume import from %s: %s", state_dir, counts)
    return counts
