"""Async SQLAlchemy + pgvector for quiz-pack-api.

Task 1.3 shipped the engine, session factory, and declarative base. Task 1.5
adds the four core ORM tables under `app.db.models`; importing this package
side-effects their registration on `Base.metadata`, so `alembic/env.py` and
the test fixtures see all tables without an explicit walk.
"""

from .base import Base, UUIDPrimaryKeyMixin
from .engine import engine, normalize_async_url
from .models import (  # noqa: F401  -- side-effect: register tables on Base.metadata
    GenerationJob,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
    append_step,
    question_to_row,
    row_to_question,
)
from .session import AsyncSessionLocal, get_session

__all__ = [
    "AsyncSessionLocal",
    "Base",
    "GenerationJob",
    "GenerationOrder",
    "QuestionPack",
    "QuestionRow",
    "UUIDPrimaryKeyMixin",
    "append_step",
    "engine",
    "get_session",
    "normalize_async_url",
    "question_to_row",
    "row_to_question",
]
