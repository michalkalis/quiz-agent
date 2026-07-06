"""Durable on-disk store for validated translations (#69).

SQLite on the existing /data Fly volume, adopting the ratings.db pattern:
sync create_engine + Base.metadata.create_all auto-schema, no Alembic, no prod DDL.
"""

from sqlalchemy import Column, String, create_engine, select
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
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
    """Thin sync SQLite store behind TranslationService's in-memory cache.

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
