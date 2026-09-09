"""The single `MetaData` the shared Core mirrors register on.

One registry, not one per module: callers build a throwaway schema with
`questions_table.metadata.create_all` (see `apps/quiz-agent/tests/`), and a
second `MetaData` would leave `question_translations` uncreated there while
`upsert`'s staleness demotion still queries it — a table that exists in
production and vanishes in tests.
"""

from __future__ import annotations

from sqlalchemy import MetaData

metadata = MetaData()

__all__ = ["metadata"]
