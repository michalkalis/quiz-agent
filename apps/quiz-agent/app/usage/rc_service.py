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
from datetime import datetime, timezone

import httpx
from sqlalchemy import func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

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
    session: AsyncSession, account_id: str, state: SubscriptionState
) -> None:
    stmt = pg_insert(Subscription).values(
        account_id=account_id,
        product_id=state.product_id,
        status=state.status,
        expires_at=state.expires_at,
        rc_original_txn_id=state.rc_original_txn_id,
        last_event_ts_ms=state.last_event_ts_ms,
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
    await _upsert_subscription(session, account_id, new_state)


async def _apply_sub_event(
    sessionmaker: async_sessionmaker[AsyncSession],
    account_id: str,
    event: SubscriptionEvent,
) -> None:
    async with sessionmaker() as session:
        await _advisory_lock(session, account_id)
        row = (
            await session.execute(
                select(Subscription).where(Subscription.account_id == account_id)
            )
        ).scalar_one_or_none()
        await _write_sub_event(session, account_id, row, event)
        await session.commit()  # commit always runs (releases the advisory lock)


# --- pack ledger persistence -------------------------------------------------


async def _grant_pack(
    sessionmaker: async_sessionmaker[AsyncSession], event: dict
) -> None:
    account_id = event["app_user_id"]
    product_id = event.get("product_id")
    store_txn_id = event.get("transaction_id")
    rc_event_id = event.get("id")
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
        )
        # Dedupe on the store txn id (global partial index) — exactly-once
        # whether the grant arrives first via /entitlements/sync or the webhook.
        stmt = stmt.on_conflict_do_nothing(
            index_elements=["store_txn_id"], index_where=text("kind = 'grant'")
        )
        await session.execute(stmt)
        await session.commit()


async def _clawback_pack(session: AsyncSession, event: dict) -> None:
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


# --- top-level webhook dispatch ----------------------------------------------


async def handle_webhook_event(
    sessionmaker: async_sessionmaker[AsyncSession], event: dict
) -> None:
    """Route one RC webhook event to the right subscription/pack write."""
    etype = event.get("type")

    if etype == "NON_RENEWING_PURCHASE":
        await _grant_pack(sessionmaker, event)
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
                await _clawback_pack(session, event)
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
                await _write_sub_event(session, account_id, current_row, sub_event)
            await session.commit()
        return

    sub_event = _normalize_sub_event(event)
    if sub_event is not None:
        await _apply_sub_event(sessionmaker, event["app_user_id"], sub_event)


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
    """
    request_date_ms = int(snapshot["request_date_ms"])
    subscriber = snapshot.get("subscriber") or {}
    subscriptions = subscriber.get("subscriptions") or {}
    non_subscriptions = subscriber.get("non_subscriptions") or {}

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
                )
                stmt = stmt.on_conflict_do_nothing(
                    index_elements=["store_txn_id"],
                    index_where=text("kind = 'grant'"),
                )
                await session.execute(stmt)

        await session.commit()
