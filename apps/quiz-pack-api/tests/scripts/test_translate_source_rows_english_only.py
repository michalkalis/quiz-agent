"""Translation sources must be English/legacy rows only.

Native sk/cs corpus rows (founder 2026-10-08) have no English original, so
`fetch_source_rows` picking one would "translate" Slovak into Slovak/Czech and
write a bogus `question_translations` row. The language predicate is the only
guard, so pin it on the SQL that actually reaches the database.
"""

from __future__ import annotations

import asyncio

from scripts.translation_runner import workset as ws


class _Result:
    def mappings(self):
        return self

    def all(self):
        return []


class _Conn:
    def __init__(self, sink: list) -> None:
        self._sink = sink

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc) -> None:
        return None

    async def execute(self, stmt):
        self._sink.append(stmt)
        return _Result()


class _Engine:
    def __init__(self) -> None:
        self.stmts: list = []

    def connect(self) -> _Conn:
        return _Conn(self.stmts)


def test_source_rows_exclude_native_sk_cs() -> None:
    engine = _Engine()
    asyncio.run(ws.fetch_source_rows(engine, ["approved"]))
    sql = str(engine.stmts[0].compile(compile_kwargs={"literal_binds": True}))
    assert "language IS NULL" in sql
    assert "language = 'en'" in sql
    assert "'sk'" not in sql and "'cs'" not in sql
