"""Async SQLAlchemy + pgvector skeleton (issue #33 Task 1.3).

The actual ORM models land in Task 1.5; this package only ships the engine,
session factory, declarative base, and the `get_session` FastAPI dependency.
"""

from .base import Base, UUIDPrimaryKeyMixin
from .engine import engine, normalize_async_url
from .session import AsyncSessionLocal, get_session

__all__ = [
    "AsyncSessionLocal",
    "Base",
    "UUIDPrimaryKeyMixin",
    "engine",
    "get_session",
    "normalize_async_url",
]
