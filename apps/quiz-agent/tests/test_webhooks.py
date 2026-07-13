"""RevenueCat webhook + /entitlements/sync tests (issue #93, Session C).

Pins the Design §2 / §4 invariants of the two RC-facing endpoints:

* **Auth fails closed / before parse** — a bad secret 401s even on a malformed
  body; an unconfigured secret 503s (never accepts).
* **Ordering guard is total in both directions** — a stale RENEWAL after a
  REFUND no-ops (watermark), a genuine REFUND revokes an active sub, and a
  webhook strictly newer than a sync snapshot still applies.
* **Split idempotency** — a pack grant is exactly-once across sync + webhook
  (dedupe on the store txn id), and a redelivered refund claws back once
  (dedupe on the rc event id).
* **Pack grants are NOT gated by the subscription watermark.**

DB-backed: the ``db_sessionmaker`` fixture targets ``TEST_DATABASE_URL`` and
skips wholesale when it is unset. The RC REST call is mocked with ``AsyncMock``.
"""

from __future__ import annotations

import asyncio
from datetime import timedelta
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from app.api.deps import require_auth_or_grace
from app.api.routes import entitlements as entitlements_route
from app.api.routes import webhooks as webhooks_route
from app.auth.identity import AuthSubject
from app.db.base import utcnow
from app.db.models import CreditLedger, Product, Subscription
from app.usage import rc_service

pytestmark = pytest.mark.asyncio

_SECRET = "rc-webhook-shared-secret-xyz"
_API_KEY = "rc-rest-secret-key"
_ACCOUNT = "acct_webhook_subject"
_SUB_PID = "com.carquiz.unlimited.monthly"
_PACK_PID = "com.carquiz.pack.questions100"


# --- seeding + helpers -------------------------------------------------------


async def _seed_products(db_sessionmaker) -> None:
    async with db_sessionmaker() as s:
        s.add(Product(product_id=_SUB_PID, kind="subscription", tier="unlimited"))
        s.add(
            Product(
                product_id=_PACK_PID,
                kind="consumable",
                tier="unlimited",
                credit_amount=100,
            )
        )
        await s.commit()


async def _balance(db_sessionmaker, account_id=_ACCOUNT) -> int:
    async with db_sessionmaker() as s:
        return int(
            (
                await s.execute(
                    select(func.coalesce(func.sum(CreditLedger.delta), 0)).where(
                        CreditLedger.account_id == account_id
                    )
                )
            ).scalar_one()
        )


async def _row_count(db_sessionmaker, kind: str) -> int:
    async with db_sessionmaker() as s:
        return int(
            (
                await s.execute(
                    select(func.count())
                    .select_from(CreditLedger)
                    .where(
                        CreditLedger.account_id == _ACCOUNT,
                        CreditLedger.kind == kind,
                    )
                )
            ).scalar_one()
        )


async def _sub_row(db_sessionmaker, account_id=_ACCOUNT) -> Subscription | None:
    async with db_sessionmaker() as s:
        return (
            await s.execute(
                select(Subscription).where(Subscription.account_id == account_id)
            )
        ).scalar_one_or_none()


def _sub_event(etype: str, *, ts_ms: int, expires_ms: int | None = None, **extra):
    event = {
        "type": etype,
        "id": f"evt_{etype}_{ts_ms}",
        "app_user_id": _ACCOUNT,
        "product_id": _SUB_PID,
        "event_timestamp_ms": ts_ms,
    }
    if expires_ms is not None:
        event["expiration_at_ms"] = expires_ms
    event.update(extra)
    return event


def _ms(days_from_now: int) -> int:
    return int((utcnow() + timedelta(days=days_from_now)).timestamp() * 1000)


@pytest_asyncio.fixture
async def client(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("REVENUECAT_WEBHOOK_SECRET", _SECRET)
    monkeypatch.setenv("REVENUECAT_API_KEY", _API_KEY)
    await _seed_products(db_sessionmaker)

    app = FastAPI()
    app.state.auth_sessionmaker = db_sessionmaker
    app.include_router(webhooks_route.router)
    app.include_router(entitlements_route.router, prefix="/api/v1")
    app.dependency_overrides[require_auth_or_grace] = lambda: AuthSubject(
        subject_id=_ACCOUNT, is_legacy=False, authenticated=True
    )

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def _post_webhook(client, event: dict, *, secret: str = _SECRET):
    return await client.post(
        "/webhooks/revenuecat",
        json={"api_version": "1.0", "event": event},
        headers={"Authorization": secret},
    )


# --- auth (fail-closed, before parse) ----------------------------------------


async def test_webhook_auth_rejects_bad_secret(client):
    """A wrong secret 401s BEFORE the body is parsed — a malformed (non-JSON)
    body with a bad secret still 401s, proving auth precedes parsing."""
    resp = await client.post(
        "/webhooks/revenuecat",
        content=b"this is not json{{{",
        headers={"Authorization": "wrong-secret", "Content-Type": "application/json"},
    )
    assert resp.status_code == 401


async def test_webhook_secret_unconfigured_fails_closed(client, monkeypatch):
    """With no configured webhook secret the endpoint fails closed (503) rather
    than accepting an unauthenticated webhook."""
    monkeypatch.delenv("REVENUECAT_WEBHOOK_SECRET", raising=False)
    resp = await client.post(
        "/webhooks/revenuecat",
        json={"event": _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(30))},
        headers={"Authorization": "anything"},
    )
    assert resp.status_code == 503


# --- subscription ordering guard ---------------------------------------------


async def test_first_event_null_watermark_applies(client, db_sessionmaker):
    """The first webhook (NULL stored watermark) applies rather than being
    dropped by a NULL comparison."""
    resp = await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(30))
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row is not None
    assert row.status == "active"
    assert row.last_event_ts_ms == 1000


async def test_refund_revokes_active_sub(client, db_sessionmaker):
    """A REFUND newer than the purchase moves the sub to expired (revoke can move
    expiry backward — the whole point of the extend/revoke split)."""
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(300))
    )
    resp = await _post_webhook(
        client, _sub_event("REFUND", ts_ms=2000, expires_ms=_ms(300))
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "expired"
    assert row.last_event_ts_ms == 2000


async def test_stale_renewal_after_refund_noop(client, db_sessionmaker):
    """An out-of-order older RENEWAL arriving AFTER a refund must not resurrect
    the sub — its event_ts <= watermark, so it is dropped."""
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(300))
    )
    await _post_webhook(client, _sub_event("REFUND", ts_ms=3000, expires_ms=_ms(300)))
    # Stale renewal (ts 2000 < watermark 3000): must no-op.
    resp = await _post_webhook(
        client, _sub_event("RENEWAL", ts_ms=2000, expires_ms=_ms(400))
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "expired"
    assert row.last_event_ts_ms == 3000


# --- sync + webhook convergence ----------------------------------------------


def _snapshot(*, request_date_ms: int, subscriptions=None, non_subscriptions=None):
    return {
        "request_date_ms": request_date_ms,
        "subscriber": {
            "subscriptions": subscriptions or {},
            "non_subscriptions": non_subscriptions or {},
        },
    }


async def test_newer_webhook_after_sync_applies(client, db_sessionmaker, monkeypatch):
    """Sync sets the watermark to request_date_ms; a RENEWAL with a strictly
    newer event_ts MUST then apply (ordering is total across sync + webhook)."""
    sync_ms = 5000
    snapshot = _snapshot(
        request_date_ms=sync_ms,
        subscriptions={
            _SUB_PID: {
                "expires_date": (utcnow() + timedelta(days=30)).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                ),
                "grace_period_expires_date": None,
                "billing_issues_detected_at": None,
                "original_transaction_id": "orig_txn_1",
            }
        },
    )
    monkeypatch.setattr(
        rc_service, "fetch_rc_subscriber", AsyncMock(return_value=snapshot)
    )

    resp = await client.post("/api/v1/entitlements/sync")
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "active"
    assert row.last_event_ts_ms == sync_ms

    # A webhook strictly newer than the snapshot applies (extends expiry).
    later_expiry = _ms(60)
    resp = await _post_webhook(
        client, _sub_event("RENEWAL", ts_ms=sync_ms + 1, expires_ms=later_expiry)
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.last_event_ts_ms == sync_ms + 1
    assert row.status == "active"


# --- pack grants + clawback --------------------------------------------------


def _pack_event(etype: str, *, ts_ms: int, txn_id: str, event_id: str):
    return {
        "type": etype,
        "id": event_id,
        "app_user_id": _ACCOUNT,
        "product_id": _PACK_PID,
        "event_timestamp_ms": ts_ms,
        "transaction_id": txn_id,
    }


async def test_grant_idempotent_sync_then_webhook(client, db_sessionmaker, monkeypatch):
    """A pack grant is exactly-once whether it lands first via /entitlements/sync
    (REST, no event id) or the NON_RENEWING_PURCHASE webhook — both carry the
    same store txn id, deduped by the GRANT partial index."""
    txn = "pack_txn_shared"
    snapshot = _snapshot(
        request_date_ms=5000,
        non_subscriptions={_PACK_PID: [{"id": "rc_ns_1", "store_transaction_id": txn}]},
    )
    monkeypatch.setattr(
        rc_service, "fetch_rc_subscriber", AsyncMock(return_value=snapshot)
    )

    resp = await client.post("/api/v1/entitlements/sync")
    assert resp.status_code == 200
    assert await _balance(db_sessionmaker) == 100

    # The later webhook for the SAME purchase must no-op (same store_txn_id).
    resp = await _post_webhook(
        client,
        _pack_event("NON_RENEWING_PURCHASE", ts_ms=6000, txn_id=txn, event_id="evt_np"),
    )
    assert resp.status_code == 200
    assert await _balance(db_sessionmaker) == 100
    assert await _row_count(db_sessionmaker, "grant") == 1


async def test_pack_grant_not_gated_by_sub_watermark(client, db_sessionmaker):
    """A pack purchase grants even when its event_timestamp is <= the sub
    watermark — pack dedup is the partial index only, never the sub watermark."""
    # Advance the subscription watermark far ahead.
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=9000, expires_ms=_ms(30))
    )
    # Pack event with a much OLDER timestamp still grants.
    resp = await _post_webhook(
        client,
        _pack_event(
            "NON_RENEWING_PURCHASE", ts_ms=1, txn_id="pack_old", event_id="evt_old"
        ),
    )
    assert resp.status_code == 200
    assert await _balance(db_sessionmaker) == 100
    assert await _row_count(db_sessionmaker, "grant") == 1


async def test_clawback_once(client, db_sessionmaker):
    """A refunded pack claws back exactly once: a redelivered refund (same rc
    event id) hits the CLAWBACK partial index and no-ops."""
    await _post_webhook(
        client,
        _pack_event(
            "NON_RENEWING_PURCHASE", ts_ms=1000, txn_id="pack_1", event_id="evt_buy"
        ),
    )
    assert await _balance(db_sessionmaker) == 100

    refund = _pack_event(
        "CANCELLATION", ts_ms=2000, txn_id="pack_1", event_id="evt_refund"
    )
    resp = await _post_webhook(client, refund)
    assert resp.status_code == 200
    assert await _balance(db_sessionmaker) == 0

    # Redelivered identical refund: deduped on rc_event_id -> still 0, one row.
    resp = await _post_webhook(client, refund)
    assert resp.status_code == 200
    assert await _balance(db_sessionmaker) == 0
    assert await _row_count(db_sessionmaker, "clawback") == 1


# --- cancellation: immediate revoke vs deferred no-op ------------------------


async def test_immediate_cancellation_revokes(client, db_sessionmaker):
    """A CANCELLATION whose expiration_at_ms is at/before the event timestamp is
    an IMMEDIATE revocation (e.g. Customer Support): it must expire the sub now,
    not leave the user entitled for the rest of a long paid period."""
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(300))
    )
    # expiration_at_ms (1000) <= event_timestamp_ms (2000) -> immediate.
    resp = await _post_webhook(
        client, _sub_event("CANCELLATION", ts_ms=2000, expires_ms=1000)
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "expired"
    assert row.last_event_ts_ms == 2000


async def test_deferred_cancellation_keeps_sub_active(client, db_sessionmaker):
    """A CANCELLATION with a FUTURE expiration_at_ms is a deferred auto-renew-off:
    the user stays entitled to period end (the later EXPIRATION flips it). It must
    NOT touch the sub row."""
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(300))
    )
    resp = await _post_webhook(
        client, _sub_event("CANCELLATION", ts_ms=2000, expires_ms=_ms(300))
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "active"
    assert row.last_event_ts_ms == 1000  # watermark unchanged — true no-op


async def test_refund_guard_atomic_under_concurrent_product_change(
    client, db_sessionmaker
):
    """The refund product-match guard and the revoke write are ONE atomic
    read-modify-write under the per-account advisory lock — the invariant a
    single-threaded test cannot catch.

    Demonstrated TOCTOU (against an unlocked guard): the account is on P1; a
    concurrent PRODUCT_CHANGE upgrades P1->P2; a REFUND of the *original* P1
    purchase arrives. If the guard reads the current sub UNLOCKED, it can see the
    still-committed P1 ("match"), then the later locked apply writes a verbatim
    P1/expired revoke over the now-active P2 row — a paying user silently loses
    their subscription.

    Deterministic two-connection interleave (mirrors
    test_entitlement.test_no_double_spend_concurrent):

    1. Txn A acquires the account's advisory lock and performs the P1->P2 upgrade
       upsert, holding its transaction (and the lock) open.
    2. Txn B processes the P1 REFUND via handle_webhook_event. WITH the fix it
       blocks on the advisory lock BEFORE reading the sub row; WITHOUT it, B
       guard-reads the stale committed P1 (match) and queues a verbatim revoke.
    3. A commits (P2 now active, lock released). B unblocks: under the fix it
       re-reads P2 under the lock, sees product P1 != P2, and no-ops.

    Result under the fix: the row is P2/active (upgrade preserved). This FAILS
    against the unlocked-guard code (row clobbered to P1/expired) and PASSES with
    the atomic guard. Needs a pool of >=2 connections (test engine default is 5).
    """
    p2_pid = "com.carquiz.unlimited.annual"
    async with db_sessionmaker() as s:
        s.add(Product(product_id=p2_pid, kind="subscription", tier="unlimited"))
        await s.commit()

    # Account starts on P1 (active).
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(300))
    )

    # REFUND is for the original P1 purchase, strictly newer than the P2 upgrade's
    # watermark (2000) so a verbatim revoke would apply if it reached the row.
    refund = _sub_event("REFUND", ts_ms=3000, expires_ms=_ms(300))
    p2_state = rc_service.SubscriptionState(
        product_id=p2_pid,
        status="active",
        expires_at=utcnow() + timedelta(days=365),
        rc_original_txn_id="orig_p2",
        last_event_ts_ms=2000,
    )

    async with db_sessionmaker() as sa:
        # (1) A holds the lock + the uncommitted P1->P2 upgrade.
        await rc_service._advisory_lock(sa, _ACCOUNT)
        await rc_service._upsert_subscription(sa, _ACCOUNT, p2_state)

        # (2) B races the P1 REFUND.
        async def _b_refund() -> None:
            await rc_service.handle_webhook_event(db_sessionmaker, refund)

        task_b = asyncio.create_task(_b_refund())
        await asyncio.sleep(0.3)  # let B block on the lock (fix) or decide (bug)

        # (3) A commits the upgrade, releasing the lock so B re-evaluates.
        await sa.commit()
        await task_b

    row = await _sub_row(db_sessionmaker)
    assert row.product_id == p2_pid  # upgrade preserved, not clobbered by P1 revoke
    assert row.status == "active"


async def test_refund_unknown_product_is_noop(client, db_sessionmaker):
    """A REFUND for a product the catalog doesn't know (unseeded) must NOT fall
    through to a sub-revoke: that would FK-500 on subscription.product_id (RC then
    redelivers forever) or clobber the account's live sub. It is a 2xx no-op that
    leaves the current subscription row untouched."""
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(300))
    )
    resp = await _post_webhook(
        client,
        _sub_event(
            "REFUND",
            ts_ms=2000,
            expires_ms=_ms(300),
            product_id="com.carquiz.unseeded.ghost",
        ),
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.product_id == _SUB_PID
    assert row.status == "active"
    assert row.last_event_ts_ms == 1000  # live sub untouched


# --- billing issue -> grace (kept-entitled) ----------------------------------


async def test_billing_issue_maps_to_grace(client, db_sessionmaker):
    """BILLING_ISSUE maps directly to status=grace with expires_at = grace-period
    end; the subscriber stays entitled through Apple's retry window rather than
    being 429'd (flaw fix 2)."""
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=1000, expires_ms=_ms(30))
    )
    grace_end = _ms(16)
    resp = await _post_webhook(
        client,
        _sub_event(
            "BILLING_ISSUE",
            ts_ms=2000,
            grace_period_expiration_at_ms=grace_end,
        ),
    )
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "grace"
    assert row.last_event_ts_ms == 2000


# --- sync must not regress behind a newer watermark --------------------------


async def test_stale_sync_does_not_regress(client, db_sessionmaker, monkeypatch):
    """A sync snapshot whose request_date_ms is BEHIND the stored watermark (a
    newer webhook already advanced it) must be a full no-op — it must not
    downgrade status/expiry nor move the watermark backward (which would re-open
    replay)."""
    # A webhook advances the watermark to 5000 (active).
    await _post_webhook(
        client, _sub_event("INITIAL_PURCHASE", ts_ms=5000, expires_ms=_ms(30))
    )
    # A late older snapshot (request_date_ms=4000 < 5000) reporting NO sub.
    snapshot = _snapshot(request_date_ms=4000, subscriptions={})
    monkeypatch.setattr(
        rc_service, "fetch_rc_subscriber", AsyncMock(return_value=snapshot)
    )
    resp = await client.post("/api/v1/entitlements/sync")
    assert resp.status_code == 200
    row = await _sub_row(db_sessionmaker)
    assert row.status == "active"  # NOT regressed to expired
    assert row.last_event_ts_ms == 5000  # watermark not moved backward


async def test_sync_upstream_failure_returns_502_not_500(client, monkeypatch):
    """An RC REST failure inside sync must surface as a handled 502, never an
    unhandled 500 (a founder-device sync hit exactly that on 2026-07-11 —
    Sentry CARQUIZ-4, #96 P1). The client treats sync as best-effort, so a
    clean upstream-error status is the contract."""
    monkeypatch.setattr(
        rc_service,
        "fetch_rc_subscriber",
        AsyncMock(side_effect=RuntimeError("RC REST down")),
    )
    resp = await client.post("/api/v1/entitlements/sync")
    assert resp.status_code == 502
    assert resp.json()["detail"] == "Entitlement sync failed"
