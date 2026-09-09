"""Coverage map → positive cell allocation for #170 (task 170.12, D1/D3).

The dedup stage only ever says *no*. This module is the positive half: it
reads how thin the live corpus is in every cell ``(language, category,
subtopic)`` (D1) and picks the next cell to generate into, biased towards
the thin ones.

Weight of a cell is ``1 / (count + K)`` with ``K = max(1, round(N_category /
cells))`` (D3). K is the corpus' own average cell depth, so:

- on an **empty** corpus every count is 0 and every weight is ``1/K`` —
  the allocation degrades to uniform *by construction*, not by a special
  case;
- once the corpus is deep, a cell far above K loses share smoothly instead
  of being hard-excluded (locked 2 — a duplicate is not a tragedy).

What it must never do is **steer blind**. A category whose live rows carry
no subtopic at all is a missing prerequisite (the 170.7 backfill has not
run), not "every cell is empty" — that state raises
``CoverageUnavailableError`` instead of silently producing a uniform draw
over a taxonomy the corpus knows nothing about. A category with *no live
rows at all* is a different thing: there is nothing to backfill, and
uniform is the correct answer.

The allocator also returns the cell's avoid-list: ``prompt_builder.py``
hard-cuts the avoid slot at 10 questions, so the trim happens **here**,
over a deterministic order (newest first, tie-break id) — otherwise the
prompt would carry an arbitrary 10 of N.

Scope of every query: live corpus rows only — ``pack_id IS NULL`` plus the
live review states, reusing the single predicate the QA dedup branch uses
(locked 3 / D5: a customer pack must never influence corpus steering).

Session I injects this as ``GenerationStage(coverage_allocator=...)``;
nothing here is wired into a stage yet.
"""

from __future__ import annotations

import logging
import random
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Protocol

from quiz_shared.database.pgvector_client import _LIVE_CORPUS_SQL
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.db.engine import build_engine, normalize_async_url
from app.generation.subtopics import subtopics_for

logger = logging.getLogger(__name__)

# `prompt_builder.py:239-243` hard-cuts the avoid slot at 10 — the module
# trims to the same number so the cut lands on a deterministic order.
AVOID_LIMIT = 10


class CoverageUnavailableError(RuntimeError):
    """The coverage map cannot steer this category (B2 — missing prerequisite)."""


@dataclass(frozen=True)
class CoverageAllocation:
    """One allocated cell plus what the prompt must not repeat inside it."""

    language: str
    category: str
    subtopic: str
    avoid_questions: tuple[str, ...]


class CoverageSource(Protocol):
    """Where the counts and the avoid-list come from (live corpus, or a fake)."""

    async def cell_counts(
        self, language: str, category: str
    ) -> Mapping[str | None, int]:
        """Live row count per subtopic in this cell family; ``None`` key = untagged rows."""

    async def recent_questions(
        self, language: str, category: str, subtopic: str, limit: int
    ) -> list[str]:
        """Question TEXTS of one cell, newest first — never answers."""


class CoverageAllocator:
    """Picks the next cell for a generation run and its avoid-list."""

    def __init__(
        self, source: CoverageSource, *, avoid_limit: int = AVOID_LIMIT
    ) -> None:
        self._source = source
        self._avoid_limit = avoid_limit

    async def allocate(
        self, language: str, category: str, seed: int
    ) -> CoverageAllocation:
        """Allocate one cell of ``category`` deterministically for ``seed``.

        Raises ``KeyError`` when the category is not in the approved taxonomy
        and ``CoverageUnavailableError`` when the category has live rows but
        not one of them is subtopic-tagged.
        """
        cells = subtopics_for(category, language)
        if not cells:
            raise CoverageUnavailableError(
                f"category {category!r} ({language}) has no approved subtopics"
            )

        counts = await self._source.cell_counts(language, category)
        tagged = sum(n for subtopic, n in counts.items() if subtopic)
        total = sum(counts.values())
        if total and not tagged:
            raise CoverageUnavailableError(
                f"category {category!r} ({language}) has {total} live row(s) but none "
                "carries a subtopic — run the subtopic backfill (170.7) before "
                "steering, or the coverage map would steer blind"
            )

        # K = the corpus' own average cell depth. Every unallocated row of the
        # category counts towards it on purpose: a half-backfilled category
        # gets a larger K, i.e. a flatter (more cautious) distribution.
        k = max(1, round(total / len(cells)))
        weights = [1.0 / (counts.get(cell, 0) + k) for cell in cells]
        subtopic = random.Random(seed).choices(cells, weights=weights, k=1)[0]

        avoid = await self._source.recent_questions(
            language, category, subtopic, self._avoid_limit
        )
        return CoverageAllocation(
            language=language,
            category=category,
            subtopic=subtopic,
            # Trim here too: the guarantee `<= AVOID_LIMIT` belongs to the
            # allocator, not to whichever source is plugged in.
            avoid_questions=tuple(avoid[: self._avoid_limit]),
        )


class PgvectorCoverageSource:
    """The live corpus behind the allocator (``pack_id IS NULL``, live states)."""

    def __init__(self, database_url: str) -> None:
        self._engine: AsyncEngine = build_engine(normalize_async_url(database_url))
        self._explained = False

    async def cell_counts(self, language: str, category: str) -> dict[str | None, int]:
        """One ``GROUP BY COALESCE(language,'en'), category, subtopic`` (D1).

        ``COALESCE`` so legacy NULL-language rows are not lost from the map
        (D2), and untagged rows come back under the ``None`` key rather than
        being dropped — the caller needs them to tell "empty category" from
        "backfill has not run".
        """
        stmt = text(
            "SELECT subtopic, count(*) AS n FROM questions "
            f"WHERE {_LIVE_CORPUS_SQL} "
            "AND COALESCE(language, 'en') = :language AND category = :category "
            "GROUP BY COALESCE(language, 'en'), category, subtopic"
        )
        params = {"language": language, "category": category}
        await self._explain_dedup_query_once()
        async with self._engine.connect() as conn:
            rows = (await conn.execute(stmt, params)).all()
        return {(row[0] or None): int(row[1]) for row in rows}

    async def recent_questions(
        self, language: str, category: str, subtopic: str, limit: int
    ) -> list[str]:
        """Newest questions of one cell, tie-broken by id so the order — and
        therefore the 10 that survive the trim — is stable across runs."""
        stmt = text(
            "SELECT question FROM questions "
            f"WHERE {_LIVE_CORPUS_SQL} "
            "AND COALESCE(language, 'en') = :language AND category = :category "
            "AND subtopic = :subtopic "
            "ORDER BY created_at DESC, id ASC LIMIT :limit"
        )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    stmt,
                    {
                        "language": language,
                        "category": category,
                        "subtopic": subtopic,
                        "limit": limit,
                    },
                )
            ).all()
        return [str(row[0]) for row in rows]

    async def _explain_dedup_query_once(self) -> None:
        """D9 tripwire, inherited not duplicated: EXPLAIN **the dedup query**
        (the only one that can pick a vector index) once per process, through
        the same pair of helpers the QA backfill uses. Explaining the coverage
        `GROUP BY` instead would be a false assurance — no vector column, so
        it can never plan an ivfflat scan. A steering run is the natural place
        to re-check, because the one-shot backfill script stops running long
        before corpus growth makes that scan likely. Imported lazily: that
        script rewrites ``sys.path`` at import time."""
        if self._explained:
            return
        self._explained = True
        from scripts.backfill_embedding_qa import explain_dedup_query, warn_if_ivfflat

        warn_if_ivfflat(await explain_dedup_query(self._engine))
