"""App Store Server Notifications V2 consumer + the revocation record (#133 gate 2).

The defect these tests exist for: a refunded purchase kept its pack credits and
its entitlement forever. The JWS-only gate shipped earlier only catches bytes
that *carry* `revocationDate`, so a client replaying the JWS it captured at
purchase time went on buying generated packs (real LLM + Tavily spend) after
Apple gave the money back.

So each test below pins one link of that chain: Apple's word is believed only
when it is Apple-signed and for our bundle; a believed REFUND/REVOKE takes the
grant back; and afterwards the reversed transaction cannot buy anything again —
not through the order route, and not through the 60 s verify cache.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import AsyncIterator, Optional
from unittest.mock import MagicMock

import httpx
import pytest
import pytest_asyncio
from fastapi import FastAPI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_arq_pool, get_jws_verifier
from app.api.v1.appstore import router as appstore_router
from app.api.v1.orders import router as orders_router
from app.config import Settings, get_settings
from app.db.models.order import GenerationOrder
from app.db.models.revoked_transaction import RevokedTransaction
from app.db.session import get_session
from app.storekit import AppleJWSVerifier, JWSRevoked
from app.storekit import revocation as revocation_module
from app.storekit.jws_cache import _jws_cache_key, verify_jws_cached
from tests._isolation import truncate_revoked_transactions
from tests.api.conftest import TEST_ADMIN_KEY, TEST_JWT_SECRET, _bearer
from tests.storekit._chain_fixtures import JWSFactory
from tests.storekit.test_jws_cache import FakeRedis

BUNDLE_ID = "com.missinghue.hangs"
PACK_TX = "2000000111111111"
SUB_TX = "2000000222222222"


def _ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def _purchase_jws(make_jws: JWSFactory, *, transaction_id: str, product_id: str) -> str:
    """The JWS a client presents at purchase time — no revocation fields.

    This is the shape that used to be un-revocable: Apple-signed, refund-free
    bytes that a client can keep and replay indefinitely.
    """
    return make_jws(
        payload_overrides={
            "transactionId": transaction_id,
            "originalTransactionId": transaction_id,
            "productId": product_id,
        }
    )


def _refunded_tx_jws(
    make_jws: JWSFactory, *, transaction_id: str, product_id: str
) -> str:
    """The inner `signedTransactionInfo` Apple embeds in a REFUND/REVOKE."""
    return make_jws(
        payload_overrides={
            "transactionId": transaction_id,
            "originalTransactionId": transaction_id,
            "productId": product_id,
            "revocationDate": _ms(datetime.now(timezone.utc) - timedelta(hours=1)),
            "revocationReason": 1,
        }
    )


def _notification_jws(
    make_jws: JWSFactory,
    *,
    notification_type: str,
    tx_jws: Optional[str] = None,
    subtype: Optional[str] = None,
    bundle_id: str = BUNDLE_ID,
    notification_uuid: str = "11111111-2222-3333-4444-555555555555",
    tamper: bool = False,
) -> str:
    """Apple's `responseBodyV2DecodedPayload`, signed by the test chain."""
    data: dict = {"bundleId": bundle_id, "environment": "Sandbox"}
    if tx_jws is not None:
        data["signedTransactionInfo"] = tx_jws
    return make_jws(
        payload_overrides={
            "notificationType": notification_type,
            "subtype": subtype,
            "notificationUUID": notification_uuid,
            "data": data,
        },
        tamper_signature=tamper,
    )


@pytest_asyncio.fixture
async def _clean_revocations(test_session: AsyncSession) -> AsyncIterator[None]:
    await truncate_revoked_transactions(test_session)
    yield


@pytest.fixture
def verifier(test_chain) -> AppleJWSVerifier:  # tests.storekit._chain_fixtures.TestChain
    return AppleJWSVerifier(test_chain.root_cert, BUNDLE_ID, "Sandbox")


@pytest_asyncio.fixture
async def client(
    test_session: AsyncSession,
    verifier: AppleJWSVerifier,
    arq_mock: MagicMock,
    _clean_orders: None,
    _clean_revocations: None,
) -> AsyncIterator[httpx.AsyncClient]:
    """Test app mounting BOTH routers.

    Deliberately one app: the point of the notification route is what it does
    to the *order* route afterwards, and a refund that is recorded but does not
    actually stop the next purchase would still be the money defect.
    """
    async def _override_session() -> AsyncIterator[AsyncSession]:
        yield test_session

    test_settings = Settings(
        admin_api_key=TEST_ADMIN_KEY, auth_jwt_secret=TEST_JWT_SECRET
    )

    test_app = FastAPI()
    test_app.include_router(orders_router)
    test_app.include_router(appstore_router)
    test_app.dependency_overrides[get_session] = _override_session
    test_app.dependency_overrides[get_jws_verifier] = lambda: verifier
    test_app.dependency_overrides[get_arq_pool] = lambda: arq_mock
    test_app.dependency_overrides[get_settings] = lambda: test_settings

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=test_app), base_url="http://test"
    ) as ac:
        yield ac


@pytest.fixture
def revocation_sentry(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Capture the reconciliation alert `record_revocation` raises to Sentry."""
    captured: list[str] = []
    monkeypatch.setattr(
        revocation_module.sentry_sdk,
        "capture_message",
        lambda message, *args, **kwargs: captured.append(message),
    )
    return captured


async def _buy_pack(client: httpx.AsyncClient, jws: str, transaction_id: str) -> str:
    """Place a real pack order with `jws`; returns its order id."""
    response = await client.post(
        "/v1/orders",
        headers={"X-StoreKit-JWS": jws, **_bearer("acct-refund-tests")},
        json={
            "transaction_id": transaction_id,
            "product_id": "pack_10",
            "prompt": "Questions about the history of espresso machines",
            "language": "en",
            "target_count": 10,
        },
    )
    assert response.status_code == 202, response.text
    return response.json()["order_id"]


@pytest.mark.asyncio
async def test_revoke_notification_revokes_the_pack_credit(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
) -> None:
    """REVOKE takes back the pack the transaction bought — and the replay too.

    Both halves are the defect. The order must stop being a live delivered
    credit, AND the pre-refund JWS the client still holds must stop buying: a
    revocation that only flips a row while the same bytes can order pack after
    pack has taken nothing back at all.
    """
    purchase_jws = _purchase_jws(
        make_jws, transaction_id=PACK_TX, product_id="pack_10"
    )
    order_id = await _buy_pack(client, purchase_jws, PACK_TX)

    response = await client.post(
        "/v1/appstore/notifications",
        json={
            "signedPayload": _notification_jws(
                make_jws,
                notification_type="REVOKE",
                tx_jws=_refunded_tx_jws(
                    make_jws, transaction_id=PACK_TX, product_id="pack_10"
                ),
            )
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "revoked"
    assert response.json()["revoked_order_ids"] == [order_id]

    order = (
        await test_session.execute(
            select(GenerationOrder).where(GenerationOrder.transaction_id == PACK_TX)
        )
    ).scalars().one()
    await test_session.refresh(order)
    assert order.status == "refunded"

    # The replay: identical Apple-signed bytes, no revocation fields on them.
    replay = await client.post(
        "/v1/orders",
        headers={"X-StoreKit-JWS": purchase_jws, **_bearer("acct-refund-tests")},
        json={
            "transaction_id": PACK_TX,
            "product_id": "pack_10",
            "prompt": "Questions about the history of espresso machines",
            "language": "en",
            "target_count": 10,
        },
    )
    assert replay.status_code == 401, replay.text
    assert "revoked" in replay.json()["detail"]


@pytest.mark.asyncio
async def test_refund_notification_revokes_a_subscription_entitlement(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    revocation_sentry: list[str],
) -> None:
    """REFUND on a subscription: recorded, denied forever, and flagged for review.

    quiz-pack-api holds no subscription table — that entitlement is granted in
    quiz-agent via RevenueCat. What this service CAN and must do is (a) refuse
    the refunded transaction any further value here, permanently, and (b) say
    loudly that a grant it could not reach may still be live. Returning a quiet
    200 with nothing revoked would be the silent-skip failure mode.
    """
    response = await client.post(
        "/v1/appstore/notifications",
        json={
            "signedPayload": _notification_jws(
                make_jws,
                notification_type="REFUND",
                tx_jws=_refunded_tx_jws(
                    make_jws, transaction_id=SUB_TX, product_id="sub_monthly"
                ),
            )
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "revoked"
    assert response.json()["revoked_order_ids"] == []
    assert any("no local grant to revoke" in m for m in revocation_sentry), (
        "a refund we could not act on must reach Sentry for reconciliation"
    )

    row = (
        await test_session.execute(
            select(RevokedTransaction).where(
                RevokedTransaction.transaction_id == SUB_TX
            )
        )
    ).scalars().one()
    assert row.notification_type == "REFUND"
    assert row.product_id == "sub_monthly"

    # Entitlement revoked in the only way this service can express it: the
    # transaction buys nothing here ever again, even on clean pre-refund bytes.
    denied = await client.post(
        "/v1/orders",
        headers={
            "X-StoreKit-JWS": _purchase_jws(
                make_jws, transaction_id=SUB_TX, product_id="sub_monthly"
            ),
            **_bearer("acct-refund-tests"),
        },
        json={
            "transaction_id": SUB_TX,
            "product_id": "pack_10",
            "prompt": "Questions about the history of espresso machines",
            "language": "en",
            "target_count": 10,
        },
    )
    assert denied.status_code == 401, denied.text


@pytest.mark.asyncio
async def test_tampered_notification_is_rejected_and_records_nothing(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
) -> None:
    """An unsigned/forged notification must not be able to revoke anything.

    This route has no key and no bearer — the signature IS the authentication.
    If a tampered payload could write a revocation row, anyone on the internet
    could disable any customer's purchases by POSTing a made-up refund.
    """
    response = await client.post(
        "/v1/appstore/notifications",
        json={
            "signedPayload": _notification_jws(
                make_jws,
                notification_type="REFUND",
                tx_jws=_refunded_tx_jws(
                    make_jws, transaction_id=PACK_TX, product_id="pack_10"
                ),
                tamper=True,
            )
        },
    )

    assert response.status_code == 401, response.text
    assert (await test_session.execute(select(RevokedTransaction))).scalars().all() == []


@pytest.mark.asyncio
async def test_notification_for_another_app_is_rejected(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
) -> None:
    """A genuinely Apple-signed notification for a DIFFERENT bundle is not ours.

    Apple signs every developer's notifications with the same root, so the
    chain check alone does not say "this is about our app". Without the bundle
    check, any other app's refund notification would revoke a transaction id
    here.
    """
    response = await client.post(
        "/v1/appstore/notifications",
        json={
            "signedPayload": _notification_jws(
                make_jws,
                notification_type="REFUND",
                tx_jws=_refunded_tx_jws(
                    make_jws, transaction_id=PACK_TX, product_id="pack_10"
                ),
                bundle_id="com.someone.else",
            )
        },
    )

    assert response.status_code == 403, response.text
    assert (await test_session.execute(select(RevokedTransaction))).scalars().all() == []


@pytest.mark.asyncio
async def test_unknown_notification_type_is_acknowledged_not_errored(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
) -> None:
    """Everything that is not REFUND/REVOKE gets a 200 and changes nothing.

    Apple retries any non-200 for days. A 500 on a notification type we do not
    handle (Apple keeps adding them) would turn one routine renewal event into
    a permanent retry loop against the money endpoint — so unknown types are
    acknowledged, and only *acknowledged*: no revocation row.
    """
    response = await client.post(
        "/v1/appstore/notifications",
        json={
            "signedPayload": _notification_jws(
                make_jws,
                notification_type="DID_RENEW",
                subtype="BILLING_RECOVERY",
                tx_jws=_refunded_tx_jws(
                    make_jws, transaction_id=PACK_TX, product_id="pack_10"
                ),
            )
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "ignored"
    assert (await test_session.execute(select(RevokedTransaction))).scalars().all() == []


@pytest.mark.asyncio
async def test_redelivered_notification_is_idempotent(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
) -> None:
    """Apple redelivers until it sees a 200 — the second delivery must be a no-op.

    Not cosmetic: a second insert would trip the unique index and 500, which
    makes Apple retry again, forever, on a revocation that already landed.
    """
    payload = {
        "signedPayload": _notification_jws(
            make_jws,
            notification_type="REFUND",
            tx_jws=_refunded_tx_jws(
                make_jws, transaction_id=PACK_TX, product_id="pack_10"
            ),
        )
    }

    first = await client.post("/v1/appstore/notifications", json=payload)
    second = await client.post("/v1/appstore/notifications", json=payload)

    assert first.json()["status"] == "revoked"
    assert second.status_code == 200
    assert second.json()["status"] == "already_revoked"
    rows = (await test_session.execute(select(RevokedTransaction))).scalars().all()
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_revoked_transaction_cannot_re_verify_through_the_cache(
    client: httpx.AsyncClient,
    verifier: AppleJWSVerifier,
    make_jws: JWSFactory,
    test_session: AsyncSession,
) -> None:
    """The 60 s verify cache must not outlive a refund.

    The cache-hit branch skips signature verification by design — and used to
    skip revocation with it, so a refund landing mid-window left up to a minute
    in which the refunded JWS still authorised retries and streams. Here the
    JWS is already cached (as it would be right after a purchase), the refund
    then lands, and the very next cached call must still be refused.
    """
    purchase_jws = _purchase_jws(
        make_jws, transaction_id=PACK_TX, product_id="pack_10"
    )
    redis = FakeRedis()
    redis.store[_jws_cache_key(purchase_jws)] = ""  # verified moments ago

    ack = await client.post(
        "/v1/appstore/notifications",
        json={
            "signedPayload": _notification_jws(
                make_jws,
                notification_type="REFUND",
                tx_jws=_refunded_tx_jws(
                    make_jws, transaction_id=PACK_TX, product_id="pack_10"
                ),
            )
        },
    )
    assert ack.json()["status"] == "revoked"

    spy = MagicMock(wraps=verifier)
    with pytest.raises(JWSRevoked, match="revoked by App Store notification REFUND"):
        await verify_jws_cached(purchase_jws, spy, redis, test_session)

    # And it was refused on the CACHE path — i.e. by the revocation record, not
    # by the verifier happening to re-run.
    spy.verify.assert_not_called()
