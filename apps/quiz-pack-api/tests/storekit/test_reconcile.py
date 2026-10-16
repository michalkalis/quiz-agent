"""Order check after a DB restore (#207 207.6).

A restore from the nightly backup loses the orders placed after the dump while
Apple keeps the money. These tests pin what the reconcile command must get
right: it finds exactly the paid, unrefunded pack purchases with no order row;
it recreates only what a surviving source row can rebuild (Apple never knows
the prompt); a rerun never creates a second order for one purchase; and its
calls to Apple authenticate the way the App Store Server API requires.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import AsyncMock

import httpx
import pytest
from app.api.v1.orders import _ADMIN_TX_PREFIX, _PRODUCT_TIERS
from app.config import Settings
from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.storekit import reconcile as reconcile_module
from app.storekit.models import SignedTransaction
from app.storekit.reconcile import (
    ADMIN_TX_PREFIX,
    PACK_PRODUCTS,
    history_any_environment,
    pack_transactions_since,
    private_key_pem,
    reconcile,
)
from app.storekit.server_api import AppStoreServerClient, ServerApiCredentials, make_token
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from tests._isolation import truncate_order_graph

APP_ROOT = Path(__file__).resolve().parents[2]
SINCE = datetime(2026, 10, 16, 2, 17, tzinfo=timezone.utc)


def _key() -> tuple[ec.EllipticCurvePrivateKey, str]:
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return key, pem


def _creds(pem: str) -> ServerApiCredentials:
    return ServerApiCredentials(
        key_id="KEY123", issuer_id="issuer-uuid", private_key_pem=pem, bundle_id="com.missinghue.hangs"
    )


def _b64d(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


# --- Apple API client -------------------------------------------------------


def test_token_is_an_es256_jwt_apple_accepts() -> None:
    # Apple rejects anything but ES256 with kid + aud + bid; a DER signature
    # (what `cryptography` emits) instead of raw r||s is a classic 401.
    key, pem = _key()
    token = make_token(_creds(pem), now=1_000)
    header_b64, payload_b64, sig_b64 = token.split(".")
    header, payload = json.loads(_b64d(header_b64)), json.loads(_b64d(payload_b64))

    assert header == {"alg": "ES256", "kid": "KEY123", "typ": "JWT"}
    assert payload["aud"] == "appstoreconnect-v1"
    assert payload["bid"] == "com.missinghue.hangs"
    assert payload["iss"] == "issuer-uuid"
    assert payload["exp"] - payload["iat"] <= 3600
    sig = _b64d(sig_b64)
    assert len(sig) == 64
    der = encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big"))
    key.public_key().verify(der, f"{header_b64}.{payload_b64}".encode(), ec.ECDSA(hashes.SHA256()))


def test_private_key_accepts_pem_or_base64() -> None:
    # A .p8 does not fit a one-line Fly secret as-is; both forms must work.
    _, pem = _key()
    assert private_key_pem(pem) == pem.strip()
    assert private_key_pem(base64.b64encode(pem.encode()).decode()) == pem


def test_history_follows_every_page() -> None:
    # A customer with many purchases spans pages; stopping at the first page
    # would report their later orders as present-and-fine without checking.
    _, pem = _key()
    seen: list[str | None] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/inApps/v2/history/tx-seed"
        assert request.headers["Authorization"].startswith("Bearer ")
        rev = request.url.params.get("revision")
        seen.append(rev)
        if rev is None:
            return httpx.Response(200, json={"signedTransactions": ["a", "b"], "hasMore": True, "revision": "r1"})
        return httpx.Response(200, json={"signedTransactions": ["c"], "hasMore": False, "revision": "r2"})

    client = AppStoreServerClient(
        _creds(pem), "Production", http=httpx.Client(transport=httpx.MockTransport(handler))
    )
    assert list(client.transaction_history("tx-seed")) == ["a", "b", "c"]
    assert seen == [None, "r1"]


def test_history_falls_back_to_sandbox_for_a_testflight_purchase() -> None:
    _, pem = _key()

    def prod(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"errorCode": 4040010})

    def sandbox(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"signedTransactions": ["s"], "hasMore": False})

    clients = [
        AppStoreServerClient(_creds(pem), "Production", http=httpx.Client(transport=httpx.MockTransport(prod))),
        AppStoreServerClient(_creds(pem), "Sandbox", http=httpx.Client(transport=httpx.MockTransport(sandbox))),
    ]
    assert history_any_environment(clients, "tx") == ["s"]


def _clients(pem: str, prod_status: int, sandbox_status: int) -> list[AppStoreServerClient]:
    def answer(status: int) -> httpx.Client:
        def handler(request: httpx.Request) -> httpx.Response:
            if status == 200:
                return httpx.Response(200, json={"signedTransactions": ["s"], "hasMore": False})
            return httpx.Response(status, json={})

        return httpx.Client(transport=httpx.MockTransport(handler))

    return [
        AppStoreServerClient(_creds(pem), "Production", http=answer(prod_status)),
        AppStoreServerClient(_creds(pem), "Sandbox", http=answer(sandbox_status)),
    ]


def test_history_moves_on_when_production_refuses_an_app_never_live_on_the_store(
    caplog: pytest.LogCaptureFixture,
) -> None:
    # 2026-10-16: with a valid key Apple answers 401 on Production while the
    # app has never been live (1.1 in review) and 200 on Sandbox. Raising on
    # that 401 crashed every reconcile dry run, so a DB restore could not
    # recover any TestFlight order.
    _, pem = _key()
    with caplog.at_level("INFO", logger="app.storekit.reconcile"):
        assert history_any_environment(_clients(pem, 401, 200), "tx") == ["s"]
    assert "Sandbox answered for tx" in caplog.text


def test_a_key_only_one_store_refuses_is_still_a_working_key() -> None:
    # Sandbox took the key and just has no such purchase: nothing to recover,
    # not a credentials failure.
    _, pem = _key()
    assert history_any_environment(_clients(pem, 401, 404), "tx") == []


def test_a_key_every_store_refuses_fails_loud() -> None:
    # A wrong or revoked key must not read as "no lost orders": the operator
    # would skip recovering paid orders after a DB restore.
    _, pem = _key()
    with pytest.raises(httpx.HTTPStatusError) as exc:
        history_any_environment(_clients(pem, 401, 401), "tx")
    assert exc.value.response.status_code == 401


def test_a_store_outage_is_not_swallowed() -> None:
    _, pem = _key()
    with pytest.raises(httpx.HTTPStatusError):
        history_any_environment(_clients(pem, 500, 200), "tx")


def test_pack_products_and_admin_prefix_match_the_order_endpoint() -> None:
    # A tier added to POST /v1/orders but not here would be paid for and
    # never reconciled.
    assert PACK_PRODUCTS == set(_PRODUCT_TIERS)
    assert ADMIN_TX_PREFIX == _ADMIN_TX_PREFIX


# --- selection of Apple transactions -----------------------------------------


def _tx(tx_id: str, *, product: str = "pack_30", bought: datetime | None = None,
        refunded: bool = False) -> SignedTransaction:
    return SignedTransaction.model_validate({
        "transactionId": tx_id,
        "originalTransactionId": tx_id,
        "productId": product,
        "bundleId": "com.missinghue.hangs",
        "purchaseDate": int(((bought or SINCE + timedelta(hours=1)).timestamp()) * 1000),
        "environment": "Production",
        "revocationDate": 1_800_000_000_000 if refunded else None,
    })


class _FakeVerifier:
    """Stands in for AppleJWSVerifier: the 'JWS' is the transaction id."""

    def __init__(self, txs: dict[str, SignedTransaction]) -> None:
        self.txs = txs

    def verify_transaction_info(self, jws: str) -> SignedTransaction:
        return self.txs[jws]


def test_selects_only_unrefunded_pack_purchases_after_the_backup() -> None:
    txs = {
        "new": _tx("new"),
        "old": _tx("old", bought=SINCE - timedelta(minutes=1)),  # in the backup
        "refunded": _tx("refunded", refunded=True),  # nothing owed
        "plus": _tx("plus", product="plus_monthly"),  # not a pack
    }
    calls: list[str] = []

    def history(seed: str) -> list[str]:
        calls.append(seed)
        return list(txs)

    found = pack_transactions_since(["new", "old"], SINCE, history, _FakeVerifier(txs))

    assert set(found) == {"new"}
    # "old" belongs to the customer whose history was already read.
    assert calls == ["new"]


# --- end to end against the DB ----------------------------------------------


@pytest.fixture(scope="module")
def _alembic_head() -> None:
    raw = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    env = os.environ.copy()
    env["DATABASE_URL"] = raw
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT, env=env, check=True, capture_output=True, text=True,
    )


def _order(tx_id: str, user: str | None) -> GenerationOrder:
    return GenerationOrder(
        user_id=user, transaction_id=tx_id, product_id="pack_30", prompt="Jazz in Prague",
        target_count=30, language="sk", status="delivered",
    )


@pytest.mark.usefixtures("_alembic_head")
async def test_recreates_lost_orders_from_the_source_and_reports_the_rest(
    engine: AsyncEngine, session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    await truncate_order_graph(session)
    session.add(_order("kept", "user-1"))
    # A generation-CLI row: not an App Store purchase, Apple would 400 on it.
    cli = _order("cli-0123456789ab", None)
    cli.product_id = "pack_cli"
    session.add(cli)
    await session.commit()

    txs = {t: _tx(t) for t in ("kept", "lost-with-row", "lost-no-row")}
    source = {
        "lost-with-row": {
            "transaction_id": "lost-with-row", "user_id": "user-1", "product_id": "pack_30",
            "prompt": "Techno in Berlin", "category": None, "theme": None, "target_count": 30,
            "language": "cs", "generation_mode": None,
            "created_at": SINCE + timedelta(hours=2),
        }
    }

    async def fake_source(url: str, since: datetime) -> dict:
        return source

    monkeypatch.setattr(reconcile_module, "_source_rows", fake_source)
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    pool = AsyncMock()

    seeds_asked: list[str] = []

    def history(seed: str) -> list[str]:
        seeds_asked.append(seed)
        return list(txs)

    async def run(apply: bool):
        return await reconcile(
            Settings(), since=SINCE, history=history,
            verifier=_FakeVerifier(txs),  # type: ignore[arg-type]
            session_factory=factory, arq_pool=pool, source_url="postgresql://src", apply=apply,
        )

    dry = await run(apply=False)
    assert {(f.tx.transaction_id, f.action) for f in dry} == {
        ("lost-with-row", "would_recreate"), ("lost-no-row", "no_source_row"),
    }
    assert pool.enqueue_job.await_count == 0
    assert not any(seed.startswith("cli-") for seed in seeds_asked)

    applied = await run(apply=True)
    recreated = [f for f in applied if f.action == "recreated"]
    assert [f.tx.transaction_id for f in recreated] == ["lost-with-row"]

    session.expire_all()
    order = (
        await session.execute(
            select(GenerationOrder).where(GenerationOrder.transaction_id == "lost-with-row")
        )
    ).scalar_one()
    # Rebuilt from the source row: the buyer gets the pack they described,
    # in their language, on their account, and it is queued for generation.
    assert (order.user_id, order.prompt, order.language, order.status) == (
        "user-1", "Techno in Berlin", "cs", "pending",
    )
    job = await session.get(GenerationJob, order.job_id)
    assert job is not None and job.status == "queued"
    pool.enqueue_job.assert_awaited_once()
    assert pool.enqueue_job.await_args.args == ("process_order", str(order.id))

    # A rerun (operator double-checks) must not create a second paid order.
    again = await run(apply=True)
    assert [(f.tx.transaction_id, f.action) for f in again] == [("lost-no-row", "no_source_row")]
    assert pool.enqueue_job.await_count == 1

    await truncate_order_graph(session)


@pytest.mark.usefixtures("_alembic_head")
async def test_source_rows_read_the_pre_restore_orders(session: AsyncSession) -> None:
    # The source query is raw SQL against another database; it must return
    # every column a recreated order needs, and skip admin and CLI orders.
    await truncate_order_graph(session)
    session.add(_order("tx-after", "user-1"))
    session.add(_order(f"{ADMIN_TX_PREFIX}x", "user-1"))
    cli = _order("cli-0123456789ab", None)
    cli.product_id = "pack_cli"
    session.add(cli)
    await session.commit()

    source_url = os.environ.get("TEST_DATABASE_URL") or os.environ["DATABASE_URL"]
    rows = await reconcile_module._source_rows(source_url, SINCE - timedelta(days=3650))

    assert set(rows) == {"tx-after"}
    assert rows["tx-after"]["prompt"] == "Jazz in Prague"
    assert rows["tx-after"]["user_id"] == "user-1"
    await truncate_order_graph(session)

