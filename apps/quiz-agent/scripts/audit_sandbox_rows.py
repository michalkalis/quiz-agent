#!/usr/bin/env python3
"""Cross-reference prod `subscription`/`credit_ledger` rows against RevenueCat
to find sandbox-origin rows the pre-#101 backend wrote as if they were real
purchases (issue #101 §3.6).

No local column distinguishes sandbox from production before migration 0006,
so classification is out-of-band: for every account with an RC-origin row,
call RC REST v1 `GET /subscribers/{app_user_id}` and match local rows to RC's
`subscriptions`/`non_subscriptions` entries by transaction id, then read that
entry's `is_sandbox` flag.

Usage (from apps/quiz-agent/, with DATABASE_URL + REVENUECAT_API_KEY set):
    python scripts/audit_sandbox_rows.py                # dry-run, report only
    python scripts/audit_sandbox_rows.py --execute --yes  # apply deletes/stamps

Dry-run (default) only prints the classification report; it never writes.
--execute requires --yes together with it, or it aborts without writing.
Take a `pg_dump` backup before running with --execute — this script does not
back up the database itself (issue #101 §4 task 5 keeps that as a separate
manual step against prod).
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from sqlalchemy import delete, or_, select, update  # noqa: E402

from app.db.engine import get_sessionmaker  # noqa: E402
from app.db.models import CreditLedger, Subscription  # noqa: E402
from app.usage.rc_service import fetch_rc_subscriber  # noqa: E402

SANDBOX = "SANDBOX"
PRODUCTION = "PRODUCTION"
UNMATCHED = "UNMATCHED"


def _sub_sandbox_map(snapshot: dict) -> dict[str, bool]:
    """RC `original_transaction_id` -> `is_sandbox` for every subscription entry."""
    subscriber = snapshot.get("subscriber") or {}
    out: dict[str, bool] = {}
    for sub in (subscriber.get("subscriptions") or {}).values():
        orig = sub.get("original_transaction_id")
        if orig:
            out[orig] = bool(sub.get("is_sandbox"))
    return out


def _pack_sandbox_map(snapshot: dict) -> dict[str, bool]:
    """RC `store_transaction_id` -> `is_sandbox` for every non-subscription (pack) entry."""
    subscriber = snapshot.get("subscriber") or {}
    out: dict[str, bool] = {}
    for purchases in (subscriber.get("non_subscriptions") or {}).values():
        for purchase in purchases:
            txn = purchase.get("store_transaction_id") or purchase.get("id")
            if txn:
                out[txn] = bool(purchase.get("is_sandbox"))
    return out


async def _fetch_snapshots(
    account_ids: list[str], api_key: str
) -> dict[str, dict | None]:
    """One RC lookup per distinct account; None means the lookup failed/404'd."""
    snapshots: dict[str, dict | None] = {}
    for account_id in account_ids:
        try:
            snapshots[account_id] = await fetch_rc_subscriber(
                account_id, api_key=api_key
            )
        except Exception as exc:  # noqa: BLE001 - report and keep auditing
            print(f"  RC lookup FAILED for {account_id}: {exc}")
            snapshots[account_id] = None
    return snapshots


def _classify_subscriptions(
    subs: list[Subscription], snapshots: dict[str, dict | None]
) -> list[tuple[Subscription, str]]:
    results = []
    for sub in subs:
        snapshot = snapshots.get(sub.account_id)
        cls = UNMATCHED
        if snapshot is not None:
            sandbox_map = _sub_sandbox_map(snapshot)
            if sub.rc_original_txn_id in sandbox_map:
                cls = SANDBOX if sandbox_map[sub.rc_original_txn_id] else PRODUCTION
        results.append((sub, cls))
    return results


def _classify_ledger_rows(
    rows: list[CreditLedger], snapshots: dict[str, dict | None]
) -> list[tuple[CreditLedger, str]]:
    results = []
    for row in rows:
        snapshot = snapshots.get(row.account_id)
        cls = UNMATCHED
        if snapshot is not None and row.store_txn_id:
            pack_map = _pack_sandbox_map(snapshot)
            if row.store_txn_id in pack_map:
                cls = SANDBOX if pack_map[row.store_txn_id] else PRODUCTION
        results.append((row, cls))
    return results


def _print_report(
    sub_cls: list[tuple[Subscription, str]],
    ledger_cls: list[tuple[CreditLedger, str]],
) -> None:
    print("\n--- subscription rows ---")
    for sub, cls in sub_cls:
        print(
            f"  [{cls:10}] account={sub.account_id} product={sub.product_id} "
            f"status={sub.status} rc_original_txn_id={sub.rc_original_txn_id}"
        )
    print("\n--- credit_ledger rows (RC-origin) ---")
    for row, cls in ledger_cls:
        print(
            f"  [{cls:10}] account={row.account_id} kind={row.kind} delta={row.delta} "
            f"store_txn_id={row.store_txn_id} rc_event_id={row.rc_event_id}"
        )

    def _counts(pairs):
        return {
            c: sum(1 for _, cc in pairs if cc == c)
            for c in (SANDBOX, PRODUCTION, UNMATCHED)
        }

    print(f"\nSubscription classification: {_counts(sub_cls)}")
    print(f"Ledger classification:       {_counts(ledger_cls)}")


async def _apply(
    sessionmaker,
    sub_cls: list[tuple[Subscription, str]],
    ledger_cls: list[tuple[CreditLedger, str]],
) -> None:
    deleted_subs = stamped_subs = deleted_ledger = stamped_ledger = 0
    async with sessionmaker() as session:
        for sub, cls in sub_cls:
            if cls == SANDBOX:
                await session.execute(
                    delete(Subscription).where(
                        Subscription.account_id == sub.account_id
                    )
                )
                deleted_subs += 1
            elif cls == PRODUCTION:
                await session.execute(
                    update(Subscription)
                    .where(Subscription.account_id == sub.account_id)
                    .values(environment="PRODUCTION")
                )
                stamped_subs += 1
            # UNMATCHED rows are left untouched — fail-closed until resolved by hand.

        for row, cls in ledger_cls:
            if cls == SANDBOX:
                await session.execute(
                    delete(CreditLedger).where(CreditLedger.id == row.id)
                )
                deleted_ledger += 1
            elif cls == PRODUCTION:
                await session.execute(
                    update(CreditLedger)
                    .where(CreditLedger.id == row.id)
                    .values(environment="PRODUCTION")
                )
                stamped_ledger += 1

        await session.commit()

    print(
        f"\nExecuted: deleted {deleted_subs} subscription row(s), "
        f"{deleted_ledger} ledger row(s); stamped {stamped_subs} subscription "
        f"row(s), {stamped_ledger} ledger row(s) environment=PRODUCTION."
    )


async def main(execute: bool, confirmed: bool) -> int:
    api_key = os.getenv("REVENUECAT_API_KEY")
    if not api_key:
        print(
            "REVENUECAT_API_KEY is not set — cannot cross-reference RC.",
            file=sys.stderr,
        )
        return 1

    sessionmaker = get_sessionmaker()
    async with sessionmaker() as session:
        subs = (await session.execute(select(Subscription))).scalars().all()
        ledger_rows = (
            (
                await session.execute(
                    select(CreditLedger).where(
                        or_(
                            CreditLedger.store_txn_id.is_not(None),
                            CreditLedger.rc_event_id.is_not(None),
                        )
                    )
                )
            )
            .scalars()
            .all()
        )

    account_ids = sorted(
        {s.account_id for s in subs} | {r.account_id for r in ledger_rows}
    )
    print(
        f"Found {len(subs)} subscription row(s), {len(ledger_rows)} RC-origin "
        f"ledger row(s) across {len(account_ids)} account(s)."
    )
    if not account_ids:
        print("Nothing to audit.")
        return 0

    print("\nQuerying RevenueCat...")
    snapshots = await _fetch_snapshots(account_ids, api_key)

    sub_cls = _classify_subscriptions(list(subs), snapshots)
    ledger_cls = _classify_ledger_rows(list(ledger_rows), snapshots)
    _print_report(sub_cls, ledger_cls)

    if not execute:
        print("\nDry-run only — no rows changed. Re-run with --execute --yes to apply.")
        return 0
    if not confirmed:
        print(
            "\n--execute requires --yes to confirm a destructive write. Aborting "
            "without changing anything.",
            file=sys.stderr,
        )
        return 1

    await _apply(sessionmaker, sub_cls, ledger_cls)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report only, write nothing (default behavior).",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Delete sandbox-origin rows and stamp PRODUCTION survivors. Requires --yes.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Confirm the destructive write requested by --execute.",
    )
    args = parser.parse_args()
    sys.exit(asyncio.run(main(execute=args.execute, confirmed=args.yes)))
