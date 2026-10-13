"""`app.corpus.covered` — the "already covered" block of a fresh-entertainment brief (#202).

Why: the block is the generator's only memory of what the corpus already asked.
A filter that lets old-year stems in wastes the 300-line budget on evergreen
rows; a cap that keeps the oldest lines instead of the newest drops exactly the
facts a fresh run is most likely to repeat. The format is what the manual
2026-10-12 run (`covered-fresh.txt`) fed the model, so it must not drift.
"""

from __future__ import annotations

from datetime import date
from types import SimpleNamespace

import pytest
from app.corpus import covered

TODAY = date(2026, 10, 13)


def _row(question: str, answer: str = "A") -> SimpleNamespace:
    return SimpleNamespace(question=question, correct_answer=answer)


class _Result:
    def __init__(self, rows) -> None:
        self._rows = rows

    def all(self):
        return self._rows


class _Conn:
    def __init__(self, rows, sql_sink) -> None:
        self._rows, self._sink = rows, sql_sink

    async def execute(self, stmt):
        self._sink.append(str(stmt))
        return _Result(self._rows)


class _Engine:
    """Rows arrive newest first, as the query's ORDER BY promises."""

    def __init__(self, rows) -> None:
        self.rows, self.sql = rows, []

    def connect(self):
        engine = self

        class _CM:
            async def __aenter__(self_inner):
                return _Conn(engine.rows, engine.sql)

            async def __aexit__(self_inner, *exc):
                return False

        return _CM()


@pytest.mark.asyncio
async def test_query_scope_matches_the_manual_run() -> None:
    engine = _Engine([])
    await covered.load_covered(engine, today=TODAY)
    sql = engine.sql[0]
    assert "pack_id is null" in sql  # customer packs are not shared corpus
    assert "review_status <> 'rejected'" in sql
    assert "language" not in sql  # EN rows also serve sk/cs sessions
    assert "order by created_at desc" in sql


@pytest.mark.asyncio
async def test_only_current_and_previous_year_stems_are_kept() -> None:
    engine = _Engine(
        [
            _row("Who won Eurovision in 2026?", "X"),
            _row("Which film won Best Picture in 2025?", "Y"),
            _row("Who painted the Mona Lisa?", "Leonardo"),
            _row("Which band released an album in 2024?", "Z"),
        ]
    )
    lines = await covered.load_covered(engine, today=TODAY)
    assert lines == [
        "- Who won Eurovision in 2026? -> X",
        "- Which film won Best Picture in 2025? -> Y",
    ]


@pytest.mark.asyncio
async def test_year_window_follows_today_not_a_hardcoded_year() -> None:
    engine = _Engine([_row("Event in 2026", "a"), _row("Event in 2027", "b")])
    lines = await covered.load_covered(engine, today=date(2027, 1, 5))
    assert [line.split(" -> ")[1] for line in lines] == ["a", "b"]


@pytest.mark.asyncio
async def test_cap_keeps_the_newest_lines() -> None:
    rows = [_row(f"Fact number {i} of 2026", str(i)) for i in range(10)]  # newest first
    lines = await covered.load_covered(_Engine(rows), today=TODAY, limit=3)
    assert [line.rsplit(" -> ", 1)[1] for line in lines] == ["0", "1", "2"]


@pytest.mark.asyncio
async def test_stem_and_answer_are_truncated_like_the_brief_did() -> None:
    long_q = "Q" * 200 + " 2026"
    lines = await covered.load_covered(
        _Engine([_row(long_q, "A" * 100)]), today=TODAY
    )
    assert lines == [f"- {'Q' * 140} -> {'A' * 40}"]


def test_block_format_matches_the_manual_brief_file() -> None:
    block = covered.format_covered_block(["- a -> b", "- c -> d"])
    assert block == (
        "Already covered in the corpus - do NOT ask about these facts again, "
        "not even reworded or reversed:\n- a -> b\n- c -> d\n"
    )
