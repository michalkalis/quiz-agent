"""DeclarativeBase for the auth/usage tables (issue #60).

Importing this module (transitively, via ``app.db.models``) is how Alembic
discovers the metadata to autogenerate migrations against — keep it
side-effect-free and lightweight. Mirrors the working ``quiz-pack-api`` pattern.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


def utcnow() -> datetime:
    return datetime.now(timezone.utc)
