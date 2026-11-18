"""Durable stores for validated translations (#69).

Production (#207.20): ``PostgresTranslationStore`` — the ``translation_cache``
table, shared by every quiz-agent machine, so a translation one machine paid
for is never bought again by another. ``TranslationStore`` (SQLite, sync
engine + ``create_all``) remains for DB-less dev and the unit tests.

Both expose the async ``get``/``put`` pair ``TranslationService`` uses.
"""

import hashlib

from sqlalchemy import Column, String, create_engine, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()


class TranslationRow(Base):
    """One validated translation, keyed by content + language + prompt version."""

    __tablename__ = "translations"

    kind = Column(String, primary_key=True)
    source_text = Column(String, primary_key=True)
    target_language = Column(String, primary_key=True)
    version = Column(String, primary_key=True)
    translated_text = Column(String, nullable=False)


class TranslationStore:
    """Thin sync SQLite store behind TranslationService's in-memory cache
    (dev/tests; production uses ``PostgresTranslationStore``).

    Mirrors SQLClient's idiom (single-row writes are microsecond-fast, called
    directly from async methods). Fail-soft guarding lives in the caller.
    """

    def __init__(self, store_url: str):
        self.engine = create_engine(store_url)
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine)

    def load_version(self, version: str) -> dict[tuple[str, str, str], str]:
        """Load all rows for `version`, keyed (kind, source_text, target_language)."""
        with self.Session() as session:
            rows = session.execute(
                select(TranslationRow).where(TranslationRow.version == version)
            ).scalars()
            return {
                (row.kind, row.source_text, row.target_language): row.translated_text
                for row in rows
            }

    def upsert(
        self,
        kind: str,
        source_text: str,
        target_language: str,
        version: str,
        translated_text: str,
    ) -> None:
        """Idempotent write-through on the composite PK (SQLite-dialect upsert)."""
        stmt = (
            sqlite_insert(TranslationRow.__table__)
            .values(
                kind=kind,
                source_text=source_text,
                target_language=target_language,
                version=version,
                translated_text=translated_text,
            )
            .on_conflict_do_update(
                index_elements=["kind", "source_text", "target_language", "version"],
                set_={"translated_text": translated_text},
            )
        )
        with self.Session() as session:
            session.execute(stmt)
            session.commit()

    async def get(
        self, kind: str, source_text: str, target_language: str, version: str
    ) -> str | None:
        with self.Session() as session:
            row = session.get(
                TranslationRow, (kind, source_text, target_language, version)
            )
            return row.translated_text if row else None

    async def put(
        self,
        kind: str,
        source_text: str,
        target_language: str,
        version: str,
        translated_text: str,
    ) -> None:
        self.upsert(kind, source_text, target_language, version, translated_text)


def source_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class PostgresTranslationStore:
    """The shared ``translation_cache`` table (#207.20)."""

    def __init__(self, sm: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sm

    async def get(
        self, kind: str, source_text: str, target_language: str, version: str
    ) -> str | None:
        from ..db.models import TranslationCacheRow as Row

        async with self._sm() as db:
            return (
                await db.execute(
                    select(Row.translated_text).where(
                        Row.kind == kind,
                        Row.source_hash == source_hash(source_text),
                        Row.target_language == target_language,
                        Row.version == version,
                    )
                )
            ).scalar_one_or_none()

    async def put(
        self,
        kind: str,
        source_text: str,
        target_language: str,
        version: str,
        translated_text: str,
    ) -> None:
        from ..db.models import TranslationCacheRow as Row

        stmt = (
            pg_insert(Row)
            .values(
                kind=kind,
                source_hash=source_hash(source_text),
                target_language=target_language,
                version=version,
                source_text=source_text,
                translated_text=translated_text,
            )
            .on_conflict_do_update(
                index_elements=["kind", "source_hash", "target_language", "version"],
                set_={"translated_text": translated_text},
            )
        )
        async with self._sm() as db:
            await db.execute(stmt)
            await db.commit()
