"""Facts the corpus already covers — the "do NOT repeat these" block of a brief.

Library home of the query ``docs/testing/runs/fresh-entertainment-2026-10-12/
covered.py`` ran by hand (#202). A fresh-entertainment brief lists the recent
fact-type stems already in the corpus so the generator does not re-ask them;
pgvector dedup still catches near-duplicates afterwards, this just saves the
generation spend.

Filter (unchanged from the manual run): every language (EN rows also serve
sk/cs sessions), entertainment, not rejected, ``pack_id IS NULL`` (customer
packs are not shared corpus), and only stems naming the current or previous
year — those are the fresh-type facts; evergreen rows are dedup's job.
"""

from __future__ import annotations

import re
from datetime import date

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

DEFAULT_LIMIT = 300

COVERED_HEADER = (
    "Already covered in the corpus - do NOT ask about these facts again, "
    "not even reworded or reversed:"
)

# Newest first so the `limit` cap drops the OLDEST facts, which are the least
# likely to be re-asked about a fresh event.
_SQL = text(
    "select question, correct_answer from questions "
    "where category = 'entertainment' and pack_id is null "
    "and review_status <> 'rejected' order by created_at desc"
)


def covered_year_pattern(today: date) -> re.Pattern[str]:
    """Stems naming the current or the previous year."""
    return re.compile(f"({today.year}|{today.year - 1})")


def format_covered_line(question: str, correct_answer: object) -> str:
    return f"- {question[:140].strip()} -> {str(correct_answer)[:40]}"


async def load_covered(
    engine_or_session: AsyncEngine | AsyncSession,
    *,
    today: date,
    limit: int = DEFAULT_LIMIT,
) -> list[str]:
    """Covered-fact lines (``- <stem> -> <answer>``), newest first, at most ``limit``."""
    if isinstance(engine_or_session, AsyncSession):
        rows = (await engine_or_session.execute(_SQL)).all()
    else:
        async with engine_or_session.connect() as conn:
            rows = (await conn.execute(_SQL)).all()
    pattern = covered_year_pattern(today)
    lines = [
        format_covered_line(r.question, r.correct_answer)
        for r in rows
        if pattern.search(r.question)
    ]
    return lines[:limit]


def format_covered_block(lines: list[str]) -> str:
    """The brief input: header line, then one line per covered fact."""
    return "\n".join([COVERED_HEADER, *lines]) + "\n"
