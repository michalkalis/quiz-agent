"""RevenueCat webhook + ``/entitlements/sync`` persistence orchestration.

Issue #93, Session C. This module is the *impure* companion to the pure
``app.usage.subscription_state`` helper: it maps RevenueCat webhook events and
REST subscriber snapshots to helper inputs, then persists to the ``subscription``
and ``credit_ledger`` tables. **All subscription-state math is delegated** to
``subscription_state`` (max-wins / revoke / watermark) — this module never
re-embeds it; it only maps RC payloads and writes rows.

Two RC surfaces are handled here:

* **Webhook** (``POST /webhooks/revenuecat``) — per-event stream. Subscription
  events fold through ``apply_subscription_event`` (watermark-ordered); pack
  events (``NON_RENEWING_PURCHASE`` / pack refund) touch the ledger and are
  **not** gated by the subscription watermark (dedup is purely the partial
  unique indexes — impl note ii).
* **Sync** (``POST /entitlements/sync``) — one-shot ``GET /subscribers/{id}``
  REST pull. Subscription state is a **full-state overwrite** of RC's current
  truth, gated only by monotonicity (``request_date_ms >= stored``); packs are
  grants keyed on ``store_transaction_id``.

Session A review notes honoured here:
  (1) ``BILLING_ISSUE`` is mapped **directly** to a grace-status event — it is
      *not* fed through ``classify_event_type`` (which raises on it).
  (2) every ``expires_at`` handed to the helper is a **tz-aware UTC** datetime
      built from RC ms/ISO timestamps (the helper compares them as-given).
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone

import httpx
import sentry_sdk
from sqlalchemy import func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..config import get_settings
from ..db.base import utcnow
from ..db.models import CreditLedger, Product, Subscription
from .subscription_state import (
    EVENT_CLASS_EXTEND,
    EVENT_CLASS_REVOKE,
    STATUS_ACTIVE,
    STATUS_EXPIRED,
    STATUS_GRACE,
    SubscriptionEvent,
    SubscriptionState,
    apply_subscription_event,
)

logger = logging.getLogger(__name__)

RC_API_BASE = "https://api.revenuecat.com/v1"

# RC event types that extend a subscription (push expiry forward via max-wins).
# PRODUCT_CHANGE is treated as an extend (upgrade/crossgrade — the common case;
# App Store downgrades are *deferred* to period end and surface later as the
# natural RENEWAL/EXPIRATION, so max-wins on the new expiry is safe). See the
# deviations note in the session report.
_SUB_EXTEND_TYPES = frozenset(
    {"INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE"}
)
# Refund-family types: immediate revocation for a sub, clawback for a pack.
_REFUND_TYPES = frozenset({"REFUND", "CHARGEBACK"})
# RC's account-transfer event: purchases re-attached from one app_user_id to
# another. Shaped unlike every other event (no app_user_id, no product/expiry, no
# environment) — see ``_handle_transfer``. Public so the route can special-case
# its id shape without duplicating the literal.
TRANSFER_EVENT_TYPE = "TRANSFER"


# --- environment gate (#101 prod/sandbox separation) --------------------------

_ENVIRONMENTS = frozenset({"PRODUCTION", "SANDBOX"})


def normalize_rc_environment(entry: dict) -> str | None:
    """Normalize an RC payload's store environment to ``PRODUCTION``/``SANDBOX``.

    Handles both RC surfaces (#101 §3.3): a **webhook event** carries
    ``environment: "SANDBOX"|"PRODUCTION"`` (optional — e.g. TRANSFER events);
    a **REST v1** subscription / non-subscription entry carries the boolean
    ``is_sandbox``. Returns ``None`` when the environment cannot be determined
    — callers must treat that as a reject, never assume PRODUCTION.
    """
    if "is_sandbox" in entry:
        is_sandbox = entry["is_sandbox"]
        # A present-but-null (or non-bool) value is *unknown*, not production.
        if not isinstance(is_sandbox, bool):
            return None
        return "SANDBOX" if is_sandbox else "PRODUCTION"
    env = entry.get("environment")
    if isinstance(env, str) and env.strip().upper() in _ENVIRONMENTS:
        return env.strip().upper()
    return None


# --- timestamp helpers -------------------------------------------------------


def _ms_to_dt(ms: int | str) -> datetime:
    """RC millisecond epoch -> tz-aware UTC datetime (Session A note 2)."""
    return datetime.fromtimestamp(int(ms) / 1000.0, tz=timezone.utc)


def _parse_rc_date(value: str | None) -> datetime | None:
    """RC ISO-8601 date string (``…Z``) -> tz-aware UTC datetime, or None."""
    if not value:
        return None
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


# --- catalog lookups ---------------------------------------------------------


async def _product_kind(session: AsyncSession, product_id: str | None) -> str | None:
    if not product_id:
        return None
    return (
        await session.execute(
            select(Product.kind).where(Product.product_id == product_id)
        )
    ).scalar_one_or_none()


async def _product_credit_amount(
    session: AsyncSession, product_id: str | None
) -> int | None:
    if not product_id:
        return None
    return (
        await session.execute(
            select(Product.credit_amount).where(Product.product_id == product_id)
        )
    ).scalar_one_or_none()


# --- subscription persistence ------------------------------------------------


def _state_from_row(row: Subscription) -> SubscriptionState:
    return SubscriptionState(
        product_id=row.product_id,
        status=row.status,
        expires_at=row.expires_at,
        rc_original_txn_id=row.rc_original_txn_id,
        last_event_ts_ms=row.last_event_ts_ms,
    )


async def _advisory_lock(session: AsyncSession, account_id: str) -> None:
    """Serialize subscription-state writes per account (same pattern as the
    credit debit) so two concurrent webhooks / a webhook racing a sync cannot
    interleave a stale read-modify-write on the single ``subscription`` row."""
    await session.execute(select(func.pg_advisory_xact_lock(func.hashtext(account_id))))


async def _upsert_subscription(
    session: AsyncSession,
    account_id: str,
    state: SubscriptionState,
    environment: str | None = None,
) -> None:
    stmt = pg_insert(Subscription).values(
        account_id=account_id,
        product_id=state.product_id,
        status=state.status,
        expires_at=state.expires_at,
        rc_original_txn_id=state.rc_original_txn_id,
        last_event_ts_ms=state.last_event_ts_ms,
        environment=environment,
        updated_at=utcnow(),
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=["account_id"],
        set_={
            "product_id": stmt.excluded.product_id,
            "status": stmt.excluded.status,
            "expires_at": stmt.excluded.expires_at,
            "rc_original_txn_id": stmt.excluded.rc_original_txn_id,
            "last_event_ts_ms": stmt.excluded.last_event_ts_ms,
            "environment": stmt.excluded.environment,
            "updated_at": utcnow(),
        },
    )
    await session.execute(stmt)


def _normalize_sub_event(event: dict) -> SubscriptionEvent | None:
    """Map an RC subscription event to a helper ``SubscriptionEvent``.

    Returns ``None`` for events that must not touch subscription state (an
    unknown type, or a *deferred* CANCELLATION — handled by the caller).
    """
    etype = event["type"]
    ts = int(event["event_timestamp_ms"])
    product_id = event.get("product_id") or ""
    orig = event.get("original_transaction_id") or event.get("transaction_id") or ""

    if etype in _SUB_EXTEND_TYPES:
        return SubscriptionEvent(
            event_class=EVENT_CLASS_EXTEND,
            product_id=product_id,
            status=STATUS_ACTIVE,
            expires_at=_ms_to_dt(event["expiration_at_ms"]),
            rc_original_txn_id=orig,
            event_ts_ms=ts,
        )
    if etype == "EXPIRATION":
        return SubscriptionEvent(
            event_class=EVENT_CLASS_REVOKE,
            product_id=product_id,
            status=STATUS_EXPIRED,
            expires_at=_ms_to_dt(event.get("expiration_at_ms") or ts),
            rc_original_txn_id=orig,
            event_ts_ms=ts,
        )
    if etype in _REFUND_TYPES or etype == "CANCELLATION":
        # Immediate revocation: status=expired, so the gate denies regardless of
        # the written expiry (revoke writes verbatim, can move expiry backward).
        # Only *immediate* CANCELLATIONs reach here — handle_webhook_event returns
        # early for deferred (future-expiry) cancellations before calling this.
        return SubscriptionEvent(
            event_class=EVENT_CLASS_REVOKE,
            product_id=product_id,
            status=STATUS_EXPIRED,
            expires_at=_ms_to_dt(event.get("expiration_at_ms") or ts),
            rc_original_txn_id=orig,
            event_ts_ms=ts,
        )
    if etype == "BILLING_ISSUE":
        # Session A note 1: map BILLING_ISSUE directly to a grace-status event
        # (do NOT feed it through classify_event_type, which raises). Written
        # verbatim (revoke-class = verbatim write) so status flips to grace and
        # expiry becomes the grace-period end; the subscriber stays entitled.
        grace_end = event.get("grace_period_expiration_at_ms") or event.get(
            "expiration_at_ms"
        )
        return SubscriptionEvent(
            event_class=EVENT_CLASS_REVOKE,
            product_id=product_id,
            status=STATUS_GRACE,
            expires_at=_ms_to_dt(grace_end or ts),
            rc_original_txn_id=orig,
            event_ts_ms=ts,
        )
    logger.warning("RevenueCat webhook: unhandled subscription event type %s", etype)
    return None


async def _write_sub_event(
    session: AsyncSession,
    account_id: str,
    current_row: Subscription | None,
    event: SubscriptionEvent,
    environment: str | None,
) -> None:
    """Fold ``event`` into ``current_row`` and persist the result, in the caller's
    (already advisory-locked) session/transaction. The caller commits.

    ``current_row`` must have been read under the same lock so the read-modify-write
    is atomic — otherwise a concurrent writer can move the row between the read and
    this apply.
    """
    current = _state_from_row(current_row) if current_row is not None else None
    new_state = apply_subscription_event(current, event)
    # apply_subscription_event returns the (unchanged) current on a stale drop;
    # only write when the state actually moved.
    if current is not None and new_state == current:
        return
    await _upsert_subscription(session, account_id, new_state, environment)


async def _apply_sub_event(
    sessionmaker: async_sessionmaker[AsyncSession],
    account_id: str,
    event: SubscriptionEvent,
    environment: str,
) -> None:
    async with sessionmaker() as session:
        await _advisory_lock(session, account_id)
        row = (
            await session.execute(
                select(Subscription).where(Subscription.account_id == account_id)
            )
        ).scalar_one_or_none()
        await _write_sub_event(session, account_id, row, event, environment)
        await session.commit()  # commit always runs (releases the advisory lock)


# --- pack ledger persistence -------------------------------------------------


async def _grant_pack(
    sessionmaker: async_sessionmaker[AsyncSession], event: dict, environment: str
) -> None:
    account_id = event["app_user_id"]
    product_id = event.get("product_id")
    store_txn_id = event.get("transaction_id")
    rc_event_id = event.get("id")
    if not store_txn_id:
        # The grant dedup below is a partial UNIQUE index on ``store_txn_id``, and
        # Postgres treats NULLs as distinct — so a txn-less grant can NEVER
        # conflict, and RC delivery is at-least-once (it retries every non-2xx).
        # Inserting it would add another +amount row on every redelivery,
        # unbounded. Skip instead — the same call the sync path already makes
        # (``if not store_txn_id: continue``). The stronger fix (a partial unique
        # index on ``COALESCE(store_txn_id, rc_event_id)``, which would let the
        # grant land *and* stay exactly-once) is deliberately deferred: it needs a
        # migration, kept out of scope for this change set.
        message = (
            "RevenueCat pack grant skipped: NON_RENEWING_PURCHASE has no "
            f"transaction_id (rc_event_id={rc_event_id!r} product={product_id!r} "
            f"account={account_id!r}) — no dedup key, so granting would "
            "double-credit on RC redelivery"
        )
        logger.warning(message)
        sentry_sdk.capture_message(message, level="warning")
        return
    async with sessionmaker() as session:
        amount = await _product_credit_amount(session, product_id)
        if not amount:
            logger.warning(
                "RevenueCat pack grant: no credit_amount for product %s — skipped",
                product_id,
            )
            return
        stmt = pg_insert(CreditLedger).values(
            account_id=account_id,
            delta=amount,
            kind="grant",
            reason="pack",
            store_txn_id=store_txn_id,
            rc_event_id=rc_event_id,
            environment=environment,
        )
        # Dedupe on the store txn id (global partial index) — exactly-once
        # whether the grant arrives first via /entitlements/sync or the webhook.
        stmt = stmt.on_conflict_do_nothing(
            index_elements=["store_txn_id"], index_where=text("kind = 'grant'")
        )
        await session.execute(stmt)
        await session.commit()


async def _clawback_pack(session: AsyncSession, event: dict, environment: str) -> None:
    """Insert the pack clawback ledger row in the caller's session (the caller
    commits). Runs inside the refund branch's advisory-locked transaction so the
    whole refund handling is one atomic unit."""
    account_id = event["app_user_id"]
    product_id = event.get("product_id")
    # store_txn_id = the ORIGINAL purchase txn (shared with the grant); dedup is
    # on the refund event's own id, so the two never collide (disjoint by kind).
    store_txn_id = event.get("transaction_id")
    rc_event_id = event.get("id")
    amount = await _product_credit_amount(session, product_id)
    if not amount:
        logger.warning(
            "RevenueCat pack clawback: no credit_amount for product %s — skipped",
            product_id,
        )
        return
    stmt = pg_insert(CreditLedger).values(
        account_id=account_id,
        delta=-amount,
        kind="clawback",
        reason="refund",
        store_txn_id=store_txn_id,
        rc_event_id=rc_event_id,
        environment=environment,
    )
    stmt = stmt.on_conflict_do_nothing(
        index_elements=["rc_event_id"], index_where=text("kind = 'clawback'")
    )
    await session.execute(stmt)


async def _report_consumption(
    sessionmaker: async_sessionmaker[AsyncSession], event: dict
) -> None:
    """CONSUMPTION_REQUEST -> report the account's balance.

    RC forwards Apple's consumption request so we can inform a refund decision.
    RC's account/keys do not exist yet (Session 0 pending) and no live endpoint
    is reachable, so this computes the balance and logs it as a report stub;
    wire the RC consumption POST once the account is provisioned.
    """
    account_id = event["app_user_id"]
    async with sessionmaker() as session:
        balance = (
            await session.execute(
                select(func.coalesce(func.sum(CreditLedger.delta), 0)).where(
                    CreditLedger.account_id == account_id
                )
            )
        ).scalar_one()
    logger.info(
        "RevenueCat CONSUMPTION_REQUEST for %s — balance=%s (report stub)",
        account_id,
        int(balance),
    )


# --- account transfer (RC TRANSFER) ------------------------------------------


def _transfer_ids(event: dict, key: str) -> list[str]:
    """The ``app_user_id``s on one side of a TRANSFER (``transferred_from`` /
    ``transferred_to``).

    RC sends arrays. A bare string is coerced into a one-element list rather than
    iterated character-by-character — that would "transfer" a handful of
    one-letter accounts instead of the real one.
    """
    value = event.get(key)
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return []
    return [str(v) for v in value if v]


async def _expire_transferred_from(
    sessionmaker: async_sessionmaker[AsyncSession], account_id: str, event_ts_ms: int
) -> None:
    """Revoke the losing account's subscription so it stops being entitled.

    A TRANSFER carries no ``product_id`` / ``expiration_at_ms``, so this keeps the
    row's own product and expiry and flips ``status`` to ``expired`` — the same
    shape as the "RC reports no subscription" branch of ``apply_sync_snapshot``,
    and exactly what ``account_is_entitled`` needs to deny. No local row means
    nothing to revoke. The flip is folded through the **revoke** class, so the
    watermark drops a replayed (or genuinely stale) TRANSFER: redelivery is a
    no-op, and a subscription event *newer* than the transfer still wins.
    """
    async with sessionmaker() as session:
        await _advisory_lock(session, account_id)
        row = (
            await session.execute(
                select(Subscription).where(Subscription.account_id == account_id)
            )
        ).scalar_one_or_none()
        if row is not None:
            await _write_sub_event(
                session,
                account_id,
                row,
                SubscriptionEvent(
                    event_class=EVENT_CLASS_REVOKE,
                    product_id=row.product_id,
                    status=STATUS_EXPIRED,
                    expires_at=row.expires_at,
                    rc_original_txn_id=row.rc_original_txn_id,
                    event_ts_ms=event_ts_ms,
                ),
                # A revoke never re-stamps the #101 audit column: keep whatever
                # environment the row was written with.
                row.environment,
            )
        await session.commit()  # commit always runs (releases the advisory lock)


async def _resync_transferred_to(
    sessionmaker: async_sessionmaker[AsyncSession], account_id: str
) -> None:
    """Grant the winning account the entitlement that was transferred to it.

    A TRANSFER has no ``product_id``/``expiration_at_ms``, so there is nothing for
    ``_normalize_sub_event`` to grant from the event the way a RENEWAL or
    INITIAL_PURCHASE does. The winning account is instead reconciled against RC's
    authoritative ``GET /subscribers`` snapshot via ``apply_sync_snapshot`` — the
    same full-state path ``/entitlements/sync`` uses, which re-applies the #101
    environment gate per entry and dedupes pack grants on the store txn id, so it
    is idempotent under RC redelivery.

    A missing API key or an RC/DB failure is logged + reported, never raised: iOS
    calls ``/entitlements/sync`` after launch/purchase, so the account self-heals
    on the next sync instead of the webhook 5xx-ing into an RC retry storm.
    """
    api_key = os.getenv("REVENUECAT_API_KEY")
    if not api_key:
        message = (
            "RevenueCat TRANSFER: REVENUECAT_API_KEY unset — cannot reconcile "
            f"transferred_to account {account_id!r}; its entitlement waits for the "
            "client's /entitlements/sync"
        )
        logger.warning(message)
        sentry_sdk.capture_message(message, level="warning")
        return
    try:
        snapshot = await fetch_rc_subscriber(account_id, api_key=api_key)
        await apply_sync_snapshot(sessionmaker, account_id, snapshot)
    except Exception:
        logger.exception(
            "RevenueCat TRANSFER: reconcile failed for transferred_to account %s "
            "— its entitlement waits for the client's /entitlements/sync",
            account_id,
        )
        sentry_sdk.capture_exception()


async def _handle_transfer(
    sessionmaker: async_sessionmaker[AsyncSession], event: dict
) -> None:
    """Move entitlement between accounts on an RC ``TRANSFER``.

    RC fires TRANSFER when a store account's purchases are re-attached to a
    different ``app_user_id`` — most commonly the same Apple ID signing in as a
    different app user. The payload is shaped unlike every other event: no
    ``app_user_id`` (only the ``transferred_from`` / ``transferred_to`` id arrays,
    which live in the same id space as ``app_user_id`` — i.e. our ``account_id``),
    no ``product_id``/``expiration_at_ms``, and no ``environment``.

    Environment (#101): a TRANSFER cannot be gated on its own payload, so it is
    processed under this deployment's ``RC_ALLOWED_ENVIRONMENT`` (an *unset*
    setting still fails closed, upstream in ``handle_webhook_event``). That is
    safe because the two sides are asymmetric: the ``transferred_from`` side only
    ever **revokes** — it can never mint entitlement or credits in the wrong
    environment — and the ``transferred_to`` side grants exclusively through
    ``apply_sync_snapshot``, which re-derives the environment from RC's
    authoritative per-entry ``is_sandbox`` rather than trusting the event.

    Losing accounts are revoked before winners are reconciled, so an id appearing
    on both sides ends up on RC's truth rather than expired.
    """
    event_ts_ms = int(event["event_timestamp_ms"])
    from_ids = _transfer_ids(event, "transferred_from")
    to_ids = _transfer_ids(event, "transferred_to")
    if not from_ids and not to_ids:
        message = (
            "RevenueCat TRANSFER carried neither transferred_from nor "
            f"transferred_to (rc_event_id={event.get('id')!r}) — nothing to move"
        )
        logger.warning(message)
        sentry_sdk.capture_message(message, level="warning")
        return
    for account_id in from_ids:
        await _expire_transferred_from(sessionmaker, account_id, event_ts_ms)
    for account_id in to_ids:
        await _resync_transferred_to(sessionmaker, account_id)


# --- top-level webhook dispatch ----------------------------------------------


async def handle_webhook_event(
    sessionmaker: async_sessionmaker[AsyncSession], event: dict
) -> None:
    """Route one RC webhook event to the right subscription/pack write.

    Environment gate first (#101 §3.3): the event's store environment must
    equal this deployment's ``RC_ALLOWED_ENVIRONMENT``. A mismatch, a missing
    environment field (never assumed PRODUCTION), or an unset setting (fail
    closed) drops the event with **no DB write of any kind**; the route still
    answers 200 so RC does not retry-storm.

    ``TRANSFER`` is the single exception: it has no ``environment`` field at all,
    so the gate would drop every account transfer (leaving the losing account
    entitled and the paying one unentitled). It is dispatched *before* the
    per-event gate and still refused when the setting is unset — see
    ``_handle_transfer`` for why that is safe in both directions.
    """
    etype = event.get("type")

    allowed = get_settings().rc_allowed_environment
    environment = normalize_rc_environment(event)
    if etype == TRANSFER_EVENT_TYPE and allowed is not None:
        await _handle_transfer(sessionmaker, event)
        return
    if allowed is None or environment != allowed:
        message = (
            "RevenueCat webhook dropped by environment gate (#101): "
            f"event type={etype!r} environment={environment!r} "
            f"allowed={allowed!r} — no write"
        )
        logger.warning(message)
        sentry_sdk.capture_message(message, level="warning")
        return

    if etype == "NON_RENEWING_PURCHASE":
        await _grant_pack(sessionmaker, event, environment)
        return
    if etype == "CONSUMPTION_REQUEST":
        await _report_consumption(sessionmaker, event)
        return

    if etype in _REFUND_TYPES or etype == "CANCELLATION":
        product_id = event.get("product_id")
        account_id = event["app_user_id"]
        # The guard (catalog kind + current-sub-product) and the revoke write MUST
        # be one atomic read-modify-write under the per-account advisory lock. If
        # the guard read ran unlocked and a concurrent PRODUCT_CHANGE (P1->P2)
        # committed before the locked apply, the verbatim P1 revoke would clobber
        # the now-active P2 row and a paying user would silently lose their sub. So
        # the whole branch (read + apply) runs in a single advisory-locked session.
        async with sessionmaker() as session:
            await _advisory_lock(session, account_id)
            kind = await _product_kind(session, product_id)

            if kind == "consumable":
                await _clawback_pack(session, event, environment)
                await session.commit()
                return

            if etype == "CANCELLATION":
                # A CANCELLATION is *deferred* by default (auto-renew off; the user
                # stays entitled to period end, the natural EXPIRATION flips it
                # later). RC signals an *immediate* cancellation (e.g. Customer
                # Support revoke) via a past ``expiration_at_ms`` — only that case
                # revokes now.
                expiry_ms = event.get("expiration_at_ms")
                event_ts_ms = int(event["event_timestamp_ms"])
                immediate = expiry_ms is not None and int(expiry_ms) <= event_ts_ms
                if not immediate:
                    logger.info(
                        "RevenueCat CANCELLATION for %s treated as deferred "
                        "(no revoke)",
                        account_id,
                    )
                    return

            # Read the current sub row under the SAME lock the revoke will write
            # under, so the product-match decision cannot be made on a stale
            # snapshot.
            current_row = (
                await session.execute(
                    select(Subscription).where(Subscription.account_id == account_id)
                )
            ).scalar_one_or_none()
            current_sub_pid = (
                current_row.product_id if current_row is not None else None
            )

            # Positive disambiguation for a sub revoke (REFUND/CHARGEBACK or an
            # immediate CANCELLATION): revoke ONLY when the catalog says this is a
            # subscription AND it is the account's current sub row. An unknown kind
            # or a mismatched/other product is a logged no-op — never a sub-revoke
            # that would FK-500 on an unseeded product or clobber the live sub row.
            if kind != "subscription" or product_id != current_sub_pid:
                logger.warning(
                    "RevenueCat %s for %s: product %r (kind=%r) is not the account's "
                    "current subscription (%r) — no-op",
                    etype,
                    account_id,
                    product_id,
                    kind,
                    current_sub_pid,
                )
                return

            sub_event = _normalize_sub_event(event)
            if sub_event is not None:
                await _write_sub_event(
                    session, account_id, current_row, sub_event, environment
                )
            await session.commit()
        return

    sub_event = _normalize_sub_event(event)
    if sub_event is not None:
        await _apply_sub_event(
            sessionmaker, event["app_user_id"], sub_event, environment
        )


# --- sync (REST full-state reconcile) ----------------------------------------


async def fetch_rc_subscriber(app_user_id: str, *, api_key: str) -> dict:
    """One-shot ``GET /subscribers/{app_user_id}`` from the RevenueCat REST API.

    Isolated as a module-level function so tests patch it with an ``AsyncMock``
    (the RC account/keys do not exist yet). Returns the parsed JSON body.
    """
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{RC_API_BASE}/subscribers/{app_user_id}",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10.0,
        )
        resp.raise_for_status()
        return resp.json()


def _reconcile_subscription_state(
    subscriptions: dict, request_date_ms: int
) -> tuple[str, str, datetime, str] | None:
    """Fold RC's ``subscriptions`` map into the single winning sub projection.

    Returns ``(product_id, status, expires_at, rc_original_txn_id)`` for the
    entry with the greatest effective expiry, or ``None`` when RC reports no
    subscription at all.
    """
    now = utcnow()
    best: tuple[datetime, str, str, datetime, str] | None = None
    for pid, sub in subscriptions.items():
        expires_at = _parse_rc_date(sub.get("expires_date"))
        if expires_at is None:
            continue
        grace_end = _parse_rc_date(sub.get("grace_period_expires_date"))
        billing_issue = sub.get("billing_issues_detected_at")
        if billing_issue and grace_end and grace_end > now:
            status, effective = STATUS_GRACE, grace_end
        elif expires_at > now:
            status, effective = STATUS_ACTIVE, expires_at
        else:
            status, effective = STATUS_EXPIRED, expires_at
        orig = sub.get("original_transaction_id") or ""
        if best is None or effective > best[0]:
            best = (effective, pid, status, expires_at, orig)
    if best is None:
        return None
    effective, pid, status, expires_at, orig = best
    return pid, status, effective, orig


async def apply_sync_snapshot(
    sessionmaker: async_sessionmaker[AsyncSession],
    account_id: str,
    snapshot: dict,
) -> None:
    """Reconcile local state to RC's authoritative ``GET /subscribers`` snapshot.

    Subscription = full-state overwrite (monotonic on ``request_date_ms``);
    packs = grants keyed on ``store_transaction_id`` (not watermark-gated).

    Environment gate (#101 §3.3): every ``subscriptions`` / ``non_subscriptions``
    entry is filtered on RC v1's per-entry ``is_sandbox`` before folding — a
    mismatched (or environment-less) entry never touches state. Unset
    ``RC_ALLOWED_ENVIRONMENT`` → the whole reconcile refuses (fail closed).
    """
    allowed = get_settings().rc_allowed_environment
    if allowed is None:
        logger.warning(
            "RevenueCat sync for %s refused: RC_ALLOWED_ENVIRONMENT unset "
            "(#101 fail closed) — no reconcile",
            account_id,
        )
        return

    request_date_ms = int(snapshot["request_date_ms"])
    subscriber = snapshot.get("subscriber") or {}
    subscriptions = {
        pid: sub
        for pid, sub in (subscriber.get("subscriptions") or {}).items()
        if normalize_rc_environment(sub) == allowed
    }
    non_subscriptions = {
        pid: [p for p in purchases if normalize_rc_environment(p) == allowed]
        for pid, purchases in (subscriber.get("non_subscriptions") or {}).items()
    }

    async with sessionmaker() as session:
        await _advisory_lock(session, account_id)

        # --- subscription: monotonic full-state overwrite --------------------
        row = (
            await session.execute(
                select(Subscription).where(Subscription.account_id == account_id)
            )
        ).scalar_one_or_none()
        stored_ts = row.last_event_ts_ms if row is not None else None
        # A stale older snapshot must never regress status/expiry/watermark.
        if stored_ts is None or request_date_ms >= stored_ts:
            reconciled = _reconcile_subscription_state(subscriptions, request_date_ms)
            if reconciled is not None:
                pid, status, expires_at, orig = reconciled
                await _upsert_subscription(
                    session,
                    account_id,
                    SubscriptionState(
                        product_id=pid,
                        status=status,
                        expires_at=expires_at,
                        rc_original_txn_id=orig,
                        last_event_ts_ms=request_date_ms,
                    ),
                    allowed,
                )
            elif row is not None:
                # RC reports no subscription -> expire the existing local row
                # (keep its product_id/expiry, flip status), advance watermark.
                await _upsert_subscription(
                    session,
                    account_id,
                    SubscriptionState(
                        product_id=row.product_id,
                        status=STATUS_EXPIRED,
                        expires_at=row.expires_at,
                        rc_original_txn_id=row.rc_original_txn_id,
                        last_event_ts_ms=request_date_ms,
                    ),
                    allowed,
                )

        # --- packs: grants keyed on store_transaction_id (not gated) ---------
        for pid, purchases in non_subscriptions.items():
            amount = await _product_credit_amount(session, pid)
            if not amount:
                continue
            for purchase in purchases:
                store_txn_id = purchase.get("store_transaction_id") or purchase.get(
                    "id"
                )
                if not store_txn_id:
                    continue
                stmt = pg_insert(CreditLedger).values(
                    account_id=account_id,
                    delta=amount,
                    kind="grant",
                    reason="pack",
                    store_txn_id=store_txn_id,
                    rc_event_id=None,
                    environment=allowed,
                )
                stmt = stmt.on_conflict_do_nothing(
                    index_elements=["store_txn_id"],
                    index_where=text("kind = 'grant'"),
                )
                await session.execute(stmt)

        await session.commit()
