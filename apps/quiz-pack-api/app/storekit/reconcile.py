"""Paid pack orders vs. App Store after a DB restore (#207 207.6).

A restore from the nightly backup (docs/setup/db-backup.md) loses every order
placed after the dump. Apple still has those purchases. This command asks the
App Store Server API for the custom-pack transactions of every customer the
restored DB knows, and lists the ones with no order row.

Apple knows the transaction, not what was ordered: the prompt, language and
account live only in our DB (the app keeps none of them once the order is
accepted). So a missing order is recreated only from a source that still has
the row, usually the pre-restore database the runbook keeps as
`quiz_pack_broken` (`--source-db`). Recreated orders start as new, queued
orders; their packs are generated again. The rest are reported for the
founder (refund via Apple, or ask the buyer to order again).

Customers whose ONLY purchases happened after the backup are invisible to the
restored DB; `--source-db` adds its transaction ids as seeds, and
`--transaction-id` takes any others (e.g. from a support email).

Run on the web machine (it has the secrets):
  fly ssh console -a quiz-pack-api -C "python -m app.storekit.reconcile --since 2026-10-16T02:17:00Z"
Dry run by default; `--apply` writes and enqueues. Prints ids and states only,
never a prompt.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import uuid
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings, get_settings
from app.db.engine import build_engine, normalize_async_url
from app.db.models.job import GenerationJob, attempt_job_id
from app.db.models.order import GenerationOrder

from .models import SignedTransaction
from .server_api import AppStoreServerClient, ServerApiCredentials
from .verifier import AppleJWSVerifier

# Same tiers as POST /v1/orders (app.api.v1.orders._PRODUCT_TIERS), kept in
# step by test_reconcile; importing the API module here would drag FastAPI in.
PACK_PRODUCTS = frozenset({"pack_10", "pack_20", "pack_30", "pack_50"})
ADMIN_TX_PREFIX = "admin-"
_SOURCE_COLUMNS = (
    "transaction_id, user_id, product_id, prompt, category, theme, "
    "target_count, language, generation_mode, created_at"
)


@dataclass(frozen=True)
class Finding:
    tx: SignedTransaction
    action: str  # "recreated" | "would_recreate" | "no_source_row"
    order_id: uuid.UUID | None = None


def private_key_pem(raw: str) -> str:
    """The .p8 PEM, accepted as-is or base64-encoded (one-line Fly secret)."""
    raw = raw.strip()
    if raw.startswith("-----BEGIN"):
        return raw.replace("\\n", "\n")
    return base64.b64decode(raw).decode()


def history_any_environment(
    clients: Sequence[AppStoreServerClient], transaction_id: str
) -> list[str]:
    """The customer's signed transactions from whichever store knows the seed.

    A TestFlight / App Review purchase lives in Sandbox, a customer's in
    Production; asking the wrong one answers 404.
    """
    for client in clients:
        try:
            return list(client.transaction_history(transaction_id))
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code != 404:
                raise
    return []


def pack_transactions_since(
    seeds: Iterable[str],
    since: datetime,
    history: Callable[[str], list[str]],
    verifier: AppleJWSVerifier,
) -> dict[str, SignedTransaction]:
    """Unrefunded custom-pack purchases since `since`, across the seeds' customers.

    One history call per customer: every transaction a history returns is a
    seed of the same customer, so later seeds of that customer are skipped.
    """
    covered: set[str] = set()
    found: dict[str, SignedTransaction] = {}
    for seed in seeds:
        if seed in covered:
            continue
        covered.add(seed)
        for jws in history(seed):
            # Same trust as at purchase time: Apple's chain, our bundle and
            # store environments. Refunds are kept out below, not rejected.
            tx = verifier.verify_transaction_info(jws)
            covered.add(tx.transaction_id)
            if (
                tx.product_id in PACK_PRODUCTS
                and tx.revocation_date is None
                and tx.purchase_date >= since
            ):
                found[tx.transaction_id] = tx
    return found


async def _seed_ids(session: AsyncSession) -> list[str]:
    """One real transaction id per customer the DB knows, newest first."""
    rows = await session.execute(
        select(GenerationOrder.user_id, GenerationOrder.transaction_id)
        .where(~GenerationOrder.transaction_id.startswith(ADMIN_TX_PREFIX))
        .order_by(GenerationOrder.created_at.desc())
    )
    seeds: list[str] = []
    seen_users: set[str] = set()
    for user_id, tx_id in rows:
        if user_id is not None:
            if user_id in seen_users:
                continue
            seen_users.add(user_id)
        seeds.append(tx_id)
    return seeds


async def _source_rows(source_url: str, since: datetime) -> dict[str, dict]:
    engine = build_engine(normalize_async_url(source_url))
    try:
        async with engine.connect() as conn:
            result = await conn.execute(
                text(
                    f"SELECT {_SOURCE_COLUMNS} FROM generation_orders "
                    "WHERE created_at >= :since AND transaction_id NOT LIKE 'admin-%'"
                ),
                {"since": since},
            )
            return {row["transaction_id"]: dict(row) for row in result.mappings()}
    finally:
        await engine.dispose()


async def _recreate(session: AsyncSession, row: dict) -> tuple[uuid.UUID, str]:
    """Insert the lost order as a fresh queued one; returns (order id, arq job id)."""
    order = GenerationOrder(
        user_id=row["user_id"],
        transaction_id=row["transaction_id"],
        product_id=row["product_id"],
        prompt=row["prompt"],
        category=row["category"],
        theme=row["theme"],
        target_count=row["target_count"],
        language=row["language"],
        generation_mode=row["generation_mode"],
        status="pending",
        created_at=row["created_at"],
        enqueued_at=datetime.now(timezone.utc),
    )
    session.add(order)
    await session.flush()
    job = GenerationJob(order_id=order.id, status="queued")
    session.add(job)
    await session.flush()
    order.job_id = job.id
    return order.id, attempt_job_id(order.id, job)


async def reconcile(
    settings: Settings,
    *,
    since: datetime,
    history: Callable[[str], list[str]],
    verifier: AppleJWSVerifier,
    session_factory: async_sessionmaker,
    arq_pool=None,
    source_url: str | None = None,
    extra_seeds: Sequence[str] = (),
    apply: bool = False,
) -> list[Finding]:
    source = await _source_rows(source_url, since) if source_url else {}
    async with session_factory() as session:
        seeds = [*extra_seeds, *(await _seed_ids(session)), *source]
        apple = pack_transactions_since(seeds, since, history, verifier)
        known = set(
            (
                await session.execute(
                    select(GenerationOrder.transaction_id).where(
                        GenerationOrder.transaction_id.in_(list(apple))
                    )
                )
            ).scalars()
        )

    findings: list[Finding] = []
    for tx_id in sorted(set(apple) - known, key=lambda t: apple[t].purchase_date):
        tx = apple[tx_id]
        row = source.get(tx_id)
        if row is None:
            findings.append(Finding(tx, "no_source_row"))
            continue
        if not apply:
            findings.append(Finding(tx, "would_recreate"))
            continue
        async with session_factory() as session:
            order_id, job_id = await _recreate(session, row)
            await session.commit()
        # A failed enqueue leaves the order 'pending'; the worker sweep
        # requeues it within minutes, so the order is never stranded.
        if arq_pool is not None:
            await arq_pool.enqueue_job(
                "process_order", str(order_id), _job_id=job_id,
                _queue_name=settings.order_queue_name,
            )
        findings.append(Finding(tx, "recreated", order_id))
    return findings


def _parse_since(raw: str) -> datetime:
    value = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


async def _main(args: argparse.Namespace) -> int:
    from arq import create_pool
    from arq.connections import RedisSettings

    from app.db.session import AsyncSessionLocal

    settings = get_settings()
    missing = [
        name
        for name in ("app_store_server_key_id", "app_store_server_issuer_id",
                     "app_store_server_private_key")
        if not getattr(settings, name)
    ]
    if missing:
        print(f"reconcile: set {', '.join(n.upper() for n in missing)} (In-App Purchase key)")
        return 2
    if not settings.storekit_environment:
        print("reconcile: STOREKIT_ENVIRONMENT is not set")
        return 2
    creds = ServerApiCredentials(
        key_id=settings.app_store_server_key_id,
        issuer_id=settings.app_store_server_issuer_id,
        private_key_pem=private_key_pem(settings.app_store_server_private_key),
        bundle_id=settings.app_bundle_id,
    )
    clients = [
        AppStoreServerClient(creds, env)
        for env in ("Production", "Sandbox")
        if env in settings.storekit_environment
    ]
    verifier = AppleJWSVerifier.from_path(
        settings.storekit_root_cert_path, settings.app_bundle_id, settings.storekit_environment
    )
    arq_pool = await create_pool(RedisSettings.from_dsn(settings.redis_url)) if args.apply else None
    try:
        findings = await reconcile(
            settings,
            since=_parse_since(args.since),
            history=lambda seed: history_any_environment(clients, seed),
            verifier=verifier,
            session_factory=AsyncSessionLocal,
            arq_pool=arq_pool,
            source_url=args.source_db,
            extra_seeds=args.transaction_id,
            apply=args.apply,
        )
    finally:
        if arq_pool is not None:
            await arq_pool.close()

    for f in findings:
        print(
            f"{f.action:15} tx={f.tx.transaction_id} product={f.tx.product_id} "
            f"bought={f.tx.purchase_date.isoformat()} env={f.tx.environment}"
            + (f" order={f.order_id}" if f.order_id else "")
        )
    lost = sum(f.action == "no_source_row" for f in findings)
    print(
        f"reconcile: {len(findings)} paid pack order(s) missing since {args.since}; "
        f"{lost} without a source row (refund via Apple or ask the buyer to reorder)"
        + ("" if args.apply else "; dry run, rerun with --apply to recreate")
    )
    return 1 if lost else 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--since", required=True, help="backup time, ISO 8601 (UTC if no zone)")
    parser.add_argument("--source-db", help="pre-restore DB URL, e.g. .../quiz_pack_broken")
    parser.add_argument("--transaction-id", action="append", default=[],
                        help="extra seed transaction id (repeatable)")
    parser.add_argument("--apply", action="store_true", help="recreate and enqueue")
    return asyncio.run(_main(parser.parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
