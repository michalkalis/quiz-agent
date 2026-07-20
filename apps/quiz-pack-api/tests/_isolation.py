"""Shared per-test DB isolation for tests that write generation_orders /
generation_jobs / question_packs / questions (backend arch review 2026-07-18,
testability finding "pack-api per-test isolation").

WHY this matters: several suites relied on unique per-test ids (uuid4
transaction_ids) plus best-effort end-of-test DELETE cleanup for isolation
against the shared *persistent* test DB. A test that fails an assertion
before its cleanup line runs leaves the row behind for the next run to trip
over — the same fragility class that caused the order-e2e CI flake
(154b95b). `truncate_order_graph` mirrors `tests/api/conftest.py`'s
`_clean_orders`: reset the whole order graph at the START of a test instead,
so isolation doesn't depend on every test succeeding.

`generation_orders`/`generation_jobs` are the roots; `TRUNCATE ... CASCADE`
also empties `question_packs` (FK's `order_id` -> generation_orders) and, via
that same CASCADE, `questions` (FK's `pack_id` -> question_packs) — see
app/db/models/{order,job,pack,question}.py for the FK graph.
"""

from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


async def truncate_order_graph(session: AsyncSession) -> None:
    """Empty generation_orders/generation_jobs and their CASCADE dependents."""
    await session.execute(
        text("TRUNCATE generation_orders, generation_jobs RESTART IDENTITY CASCADE")
    )
    await session.commit()
