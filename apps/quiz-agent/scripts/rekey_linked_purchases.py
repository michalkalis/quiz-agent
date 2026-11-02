#!/usr/bin/env python3
"""One-off backfill for #217.2: move purchases still keyed to an anon id that is
already linked to an account (``anonymous_identities.upgraded_to_user_id``) onto
that account: custom pack orders + packs (quiz-pack-api tables in the same
Postgres) and ``credit_ledger`` rows.

Before #217.2 sign-in moved credit only once per anon and never moved packs, so
a pack bought anonymously disappeared from My packs after Sign in with Apple.
Sign-in now runs the same re-key (``rekey_purchases``) every time; this script
applies it once to every existing linked anon. Idempotent: a second run finds
nothing to move. Anons that are not linked (or were de-linked by an account
erasure) are never touched.

Usage (from apps/quiz-agent/ or as /app/scripts/… on the Fly machine, DATABASE_URL set):
    python scripts/rekey_linked_purchases.py                # dry-run, report only
    python scripts/rekey_linked_purchases.py --execute --yes  # apply, one commit
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from sqlalchemy import text  # noqa: E402

from app.db.engine import get_sessionmaker  # noqa: E402
from app.usage.account_merge import rekey_purchases  # noqa: E402

# Rows still on a linked anon id, per table (what the re-key would move).
_PENDING = {
    table: text(
        f"SELECT a.anon_id, a.upgraded_to_user_id, count(*) FROM {table} t "
        f"JOIN anonymous_identities a ON t.{column} = a.anon_id "
        "WHERE a.upgraded_to_user_id IS NOT NULL "
        "GROUP BY a.anon_id, a.upgraded_to_user_id"
    )
    for table, column in (
        ("generation_orders", "user_id"),
        ("question_packs", "user_id"),
        ("credit_ledger", "account_id"),
    )
}


async def _pending(session) -> dict[tuple[str, str], dict[str, int]]:
    """(anon_id, account_id) -> {table: rows still on the anon id}."""
    out: dict[tuple[str, str], dict[str, int]] = {}
    for table, query in _PENDING.items():
        for anon_id, account_id, count in await session.execute(query):
            out.setdefault((anon_id, account_id), {})[table] = count
    return out


async def main(execute: bool, confirmed: bool) -> int:
    if execute and not confirmed:
        print("--execute requires --yes. Aborting, nothing changed.", file=sys.stderr)
        return 1
    async with get_sessionmaker()() as session:
        pending = await _pending(session)
        for (anon_id, account_id), counts in sorted(pending.items()):
            print(f"  anon={anon_id} -> account={account_id} {counts}")
        totals = {t: sum(c.get(t, 0) for c in pending.values()) for t in _PENDING}
        print(f"{len(pending)} linked anon(s) with purchases to move: {totals}")
        if not pending:
            return 0
        if not execute:
            print("Dry-run only, nothing changed. Re-run with --execute --yes.")
            return 0
        for anon_id, account_id in sorted(pending):
            await rekey_purchases(session, anon_id, account_id)
        await session.commit()
        left = await _pending(session)
    print(f"Executed. Linked anons still holding purchases: {len(left)} (expected 0)")
    return 0 if not left else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--execute", action="store_true", help="Apply the re-key. Requires --yes."
    )
    parser.add_argument("--yes", action="store_true", help="Confirm --execute.")
    args = parser.parse_args()
    sys.exit(asyncio.run(main(args.execute, args.yes)))
