"""PendingStore — narrow seam over a store of pre-approval Question records.

Sibling of `QuestionStore` (issue 22). Where `QuestionStore` is the system of
record for *approved* questions in ChromaDB, `PendingStore` is the system of
record for questions in `pending_review` / `needs_revision` state. Approval
moves a question from this store to `QuestionStore` and deletes the original.

Two callers (`add` and `upsert`) share serialization in one place via
`Question.model_dump_json` / `Question.model_validate_json`. ChromaDB is not
involved — pending questions must not pollute semantic search results.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime
from typing import Any, Dict, List, Optional, Protocol

from sqlalchemy import Column, DateTime, String, Text, create_engine
from sqlalchemy.orm import Session, declarative_base, sessionmaker

from ..models.question import Question

logger = logging.getLogger(__name__)


class PendingStore(Protocol):
    """Narrow interface for pre-approval question persistence.

    Implementations are responsible for:
    - Serializing/deserializing `Question` to/from their backing store
    - Keeping `add` and `upsert` distinct: `add` errors on existing ID,
      `upsert` always writes
    - Filtering by `review_status` in `list`/`count`
    """

    def add(self, question: Question) -> bool: ...
    def upsert(self, question: Question) -> bool: ...
    def get(self, question_id: str) -> Optional[Question]: ...
    def delete(self, question_id: str) -> bool: ...
    def list(
        self,
        status: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Question]: ...
    def count(self, status: Optional[str] = None) -> int: ...


# ── SQLite adapter ─────────────────────────────────────────────────────────

_Base = declarative_base()


class _PendingQuestionDB(_Base):
    """SQLAlchemy model for pending review questions."""
    __tablename__ = "pending_questions"

    id = Column(String, primary_key=True)
    data_json = Column(Text, nullable=False)
    review_status = Column(String, nullable=False, index=True)
    created_at = Column(DateTime, nullable=False, index=True)
    updated_at = Column(DateTime, nullable=False)


class SQLitePendingStore:
    """SQLite-backed `PendingStore`.

    One row per pending question, full `Question` JSON in `data_json`.
    `review_status` and `created_at` are denormalized for cheap filtering.
    """

    def __init__(self, database_url: Optional[str] = None):
        """Initialize. Defaults to `sqlite:///./data/pending.db` (matches the
        `ratings.db` convention; runs alongside the existing data mount)."""
        if database_url is None:
            database_url = os.getenv(
                "PENDING_DATABASE_URL",
                "sqlite:///./data/pending.db",
            )
        self.engine = create_engine(database_url, echo=False)
        _Base.metadata.create_all(self.engine)
        self._SessionLocal = sessionmaker(bind=self.engine)

    def _session(self) -> Session:
        return self._SessionLocal()

    # ── Writes ─────────────────────────────────────────────────────────────

    def add(self, question: Question) -> bool:
        """Add a new pending question. Errors if ID already exists."""
        session = self._session()
        try:
            now = datetime.now()
            session.add(_PendingQuestionDB(
                id=question.id,
                data_json=question.model_dump_json(),
                review_status=question.review_status,
                created_at=question.created_at or now,
                updated_at=now,
            ))
            session.commit()
            return True
        except Exception as e:
            logger.error("Error adding pending question %s: %s", question.id, e)
            session.rollback()
            return False
        finally:
            session.close()

    def upsert(self, question: Question) -> bool:
        """Insert or replace. Canonical write — never silently no-ops."""
        session = self._session()
        try:
            now = datetime.now()
            existing = session.get(_PendingQuestionDB, question.id)
            if existing is not None:
                existing.data_json = question.model_dump_json()
                existing.review_status = question.review_status
                existing.updated_at = now
            else:
                session.add(_PendingQuestionDB(
                    id=question.id,
                    data_json=question.model_dump_json(),
                    review_status=question.review_status,
                    created_at=question.created_at or now,
                    updated_at=now,
                ))
            session.commit()
            return True
        except Exception as e:
            logger.error("Error upserting pending question %s: %s", question.id, e, exc_info=True)
            session.rollback()
            return False
        finally:
            session.close()

    def delete(self, question_id: str) -> bool:
        session = self._session()
        try:
            existing = session.get(_PendingQuestionDB, question_id)
            if existing is None:
                return False
            session.delete(existing)
            session.commit()
            return True
        except Exception as e:
            logger.error("Error deleting pending question %s: %s", question_id, e)
            session.rollback()
            return False
        finally:
            session.close()

    # ── Reads ──────────────────────────────────────────────────────────────

    def get(self, question_id: str) -> Optional[Question]:
        session = self._session()
        try:
            row = session.get(_PendingQuestionDB, question_id)
            if row is None:
                return None
            return Question.model_validate_json(row.data_json)
        except Exception as e:
            logger.error("Error getting pending question %s: %s", question_id, e)
            return None
        finally:
            session.close()

    def list(
        self,
        status: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Question]:
        session = self._session()
        try:
            query = session.query(_PendingQuestionDB)
            if status is not None:
                query = query.filter(_PendingQuestionDB.review_status == status)
            rows = (
                query.order_by(_PendingQuestionDB.created_at.asc())
                .offset(offset)
                .limit(limit)
                .all()
            )
            return [Question.model_validate_json(r.data_json) for r in rows]
        except Exception as e:
            logger.error("Error listing pending questions: %s", e)
            return []
        finally:
            session.close()

    def count(self, status: Optional[str] = None) -> int:
        session = self._session()
        try:
            query = session.query(_PendingQuestionDB)
            if status is not None:
                query = query.filter(_PendingQuestionDB.review_status == status)
            return query.count()
        except Exception as e:
            logger.error("Error counting pending questions: %s", e)
            return 0
        finally:
            session.close()


# ── In-memory adapter (tests) ──────────────────────────────────────────────


class InMemoryPendingStore:
    """In-memory `PendingStore`. Use in tests to avoid touching disk."""

    def __init__(self) -> None:
        self._items: Dict[str, Question] = {}

    def add(self, question: Question) -> bool:
        if question.id in self._items:
            logger.error("Pending question %s already exists", question.id)
            return False
        self._items[question.id] = question.model_copy(deep=True)
        return True

    def upsert(self, question: Question) -> bool:
        self._items[question.id] = question.model_copy(deep=True)
        return True

    def get(self, question_id: str) -> Optional[Question]:
        item = self._items.get(question_id)
        return item.model_copy(deep=True) if item else None

    def delete(self, question_id: str) -> bool:
        return self._items.pop(question_id, None) is not None

    def list(
        self,
        status: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> List[Question]:
        items = list(self._items.values())
        if status is not None:
            items = [q for q in items if q.review_status == status]
        items.sort(key=lambda q: q.created_at)
        sliced = items[offset:offset + limit]
        return [q.model_copy(deep=True) for q in sliced]

    def count(self, status: Optional[str] = None) -> int:
        if status is None:
            return len(self._items)
        return sum(1 for q in self._items.values() if q.review_status == status)


__all__ = [
    "PendingStore",
    "SQLitePendingStore",
    "InMemoryPendingStore",
]
