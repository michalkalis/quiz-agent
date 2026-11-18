"""Purchases follow the Apple account across sign-in (#217.2 — public App Store release).

A custom pack (€8.99) or question credit bought while anonymous is keyed to the
anon id. Sign in with Apple switches the device to the account id, so anything
left on the anon id disappears from My packs, cannot be played, and its credit is
gone. These pin that ``POST /auth/apple`` moves those purchases onto the account:

- on the first sign-in, and again on every later one (sign-out returns the
  device to the same, already linked anon, which can buy again);
- idempotently (signing in twice duplicates nothing);
- never on the 409 path (an anon that belongs to another account keeps its
  purchases, nothing moves to the account trying to claim it).

"In GET /v1/orders" is asserted on ``generation_orders.user_id`` (that endpoint
filters on exactly it); "playable" runs the real play-time ownership check. Pack
tables are quiz-pack-api's (alembic-managed in the shared test DB), so rows are
cleaned up explicitly.
"""

from __future__ import annotations

import importlib.util
import uuid
from pathlib import Path

import pytest
import pytest_asyncio
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select, text

from app.api.routes.sessions import _require_pack_ownership
from app.db.models import AnonymousIdentity, CreditLedger
from app.rate_limit import limiter
from tests.test_auth_apple_endpoint import _call_apple, _make_anon, _make_app

pytestmark = pytest.mark.asyncio


@pytest.fixture(scope="module")
def keypair() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest_asyncio.fixture
async def client(db_sessionmaker, keypair):
    """The real /auth/apple route with Apple mocked (see test_auth_apple_endpoint)."""
    limiter.reset()
    app = _make_app(db_sessionmaker, keypair.public_key())
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


@pytest_asyncio.fixture
async def orders(db_sessionmaker):
    """Seeds an order + its delivered pack for an owner; deletes them afterwards
    (packs cascade with their order)."""
    created: list[uuid.UUID] = []

    async def seed(owner: str) -> uuid.UUID:
        order_id, pack_id = uuid.uuid4(), uuid.uuid4()
        async with db_sessionmaker() as s:
            await s.execute(
                text(
                    "INSERT INTO generation_orders (id, user_id, transaction_id, "
                    "product_id, prompt, target_count, language) VALUES "
                    "(:id, :uid, :txn, 'pack_30', 'my pack', 30, 'en')"
                ),
                {"id": order_id, "uid": owner, "txn": f"txn-{order_id}"},
            )
            await s.execute(
                text(
                    "INSERT INTO question_packs (id, order_id, user_id, prompt, "
                    "target_count, language) VALUES (:id, :oid, :uid, 'my pack', 30, 'en')"
                ),
                {"id": pack_id, "oid": order_id, "uid": owner},
            )
            await s.commit()
        created.append(order_id)
        return pack_id

    yield seed
    async with db_sessionmaker() as s:
        for order_id in created:
            await s.execute(
                text("DELETE FROM generation_orders WHERE id = :i"), {"i": order_id}
            )
        await s.commit()


async def _pack_owners(db, pack_id: uuid.UUID) -> tuple[str, str]:
    """(order owner, pack owner) for a pack."""
    async with db() as s:
        row = (
            await s.execute(
                text(
                    "SELECT o.user_id, p.user_id FROM question_packs p "
                    "JOIN generation_orders o ON o.id = p.order_id WHERE p.id = :p"
                ),
                {"p": pack_id},
            )
        ).one()
    return row[0], row[1]


async def _order_count(db, owner: str) -> int:
    async with db() as s:
        return (
            await s.execute(
                text("SELECT count(*) FROM generation_orders WHERE user_id = :u"),
                {"u": owner},
            )
        ).scalar_one()


async def _assert_playable_only_by(db, pack_id, owner: str, other: str) -> None:
    await _require_pack_ownership(pack_id, owner, db)  # raises if not owned
    with pytest.raises(HTTPException):
        await _require_pack_ownership(pack_id, other, db)


async def _sign_in(client, keypair, sub: str, bearer: str) -> str:
    r = await _call_apple(client, keypair, sub=sub, bearer=bearer)
    assert r.status_code == 200, r.text
    return r.json()["anon_id"]  # the account id (legacy field name)


async def test_pack_bought_anonymously_is_listed_and_playable_after_sign_in(
    client, keypair, db_sessionmaker, orders
):
    """The headline bug: a paid pack bought before signing in must still be in
    My packs and playable afterwards, and no longer by the anon id."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    pack_id = await orders(anon_id)

    user_id = await _sign_in(client, keypair, "apple.sub.pack1", bearer)

    assert await _pack_owners(db_sessionmaker, pack_id) == (user_id, user_id)
    await _assert_playable_only_by(db_sessionmaker, pack_id, user_id, anon_id)


async def test_pack_bought_after_sign_out_moves_on_the_next_sign_in(
    client, keypair, db_sessionmaker, orders
):
    """Sign-out returns the device to the SAME linked anon, so its usage is not
    folded again; a pack bought in between must still move on the next sign-in,
    or it is lost exactly like the first-sign-in bug."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    first = await orders(anon_id)
    user_id = await _sign_in(client, keypair, "apple.sub.pack2", bearer)

    second = await orders(anon_id)  # signed out, bought again as the anon
    assert await _sign_in(client, keypair, "apple.sub.pack2", bearer) == user_id

    assert await _pack_owners(db_sessionmaker, first) == (user_id, user_id)
    assert await _pack_owners(db_sessionmaker, second) == (user_id, user_id)
    await _assert_playable_only_by(db_sessionmaker, second, user_id, anon_id)


async def test_repeated_sign_in_duplicates_no_pack_or_credit(
    client, keypair, db_sessionmaker, orders
):
    """A replayed sign-in must be a no-op for purchases: still one order, and
    the credit balance is not counted twice."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await orders(anon_id)
    await _seed_credit(db_sessionmaker, anon_id, 100, "txn-idem")

    user_id = await _sign_in(client, keypair, "apple.sub.idem2", bearer)
    await _sign_in(client, keypair, "apple.sub.idem2", bearer)

    assert await _order_count(db_sessionmaker, user_id) == 1
    assert await _order_count(db_sessionmaker, anon_id) == 0
    assert await _balance(db_sessionmaker, user_id) == 100


async def test_conflict_409_moves_no_purchase(client, keypair, db_sessionmaker, orders):
    """An anon already linked to account A cannot be claimed by B: the 409 must
    stay, and what the anon bought since must move to neither B nor (on this
    rolled-back call) A."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _sign_in(client, keypair, "apple.sub.ownerA", bearer)
    pack_id = await orders(anon_id)
    await _seed_credit(db_sessionmaker, anon_id, 50, "txn-409")

    r = await _call_apple(client, keypair, sub="apple.sub.thiefB", bearer=bearer)

    assert r.status_code == 409
    assert await _pack_owners(db_sessionmaker, pack_id) == (anon_id, anon_id)
    assert await _balance(db_sessionmaker, anon_id) == 50


async def test_credit_bought_after_sign_out_moves_on_the_next_sign_in(
    client, keypair, db_sessionmaker
):
    """Same gap as packs: the credit fold used to run once per anon, so credit
    bought after sign-out on the same device stayed on the anon id."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _seed_credit(db_sessionmaker, anon_id, 100, "txn-first")
    user_id = await _sign_in(client, keypair, "apple.sub.credit", bearer)
    assert await _balance(db_sessionmaker, user_id) == 100

    await _seed_credit(db_sessionmaker, anon_id, 30, "txn-after-sign-out")
    await _sign_in(client, keypair, "apple.sub.credit", bearer)

    assert await _balance(db_sessionmaker, user_id) == 130
    assert await _balance(db_sessionmaker, anon_id) == 0


async def _seed_credit(db, account_id: str, amount: int, txn: str) -> None:
    async with db() as s:
        s.add(
            CreditLedger(
                account_id=account_id,
                delta=amount,
                kind="grant",
                reason="pack_purchase",
                store_txn_id=txn,
            )
        )
        await s.commit()


async def _balance(db, account_id: str) -> int:
    async with db() as s:
        return int(
            (
                await s.execute(
                    select(func.coalesce(func.sum(CreditLedger.delta), 0)).where(
                        CreditLedger.account_id == account_id
                    )
                )
            ).scalar_one()
        )


def _backfill_module():
    path = Path(__file__).resolve().parents[1] / "scripts" / "rekey_linked_purchases.py"
    spec = importlib.util.spec_from_file_location("rekey_linked_purchases", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def test_backfill_moves_only_linked_anons_and_dry_run_writes_nothing(
    db_sessionmaker, orders, monkeypatch
):
    """The one-off backfill for anons linked before #217.2. It moves paid data,
    so: the default dry run must change nothing, --execute moves a linked anon's
    pack and credit, an unlinked anon (never signed in, or de-linked by account
    erasure) keeps its own, and a second run is a no-op."""
    linked, lone, user_id = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
    async with db_sessionmaker() as s:
        s.add(AnonymousIdentity(anon_id=linked, upgraded_to_user_id=user_id))
        s.add(AnonymousIdentity(anon_id=lone))
        await s.commit()
    linked_pack, lone_pack = await orders(linked), await orders(lone)
    await _seed_credit(db_sessionmaker, linked, 100, "txn-backfill")
    backfill = _backfill_module()
    monkeypatch.setattr(backfill, "get_sessionmaker", lambda: db_sessionmaker)

    assert await backfill.main(execute=False, confirmed=False) == 0
    assert await _pack_owners(db_sessionmaker, linked_pack) == (linked, linked)

    assert await backfill.main(execute=True, confirmed=True) == 0
    assert await _pack_owners(db_sessionmaker, linked_pack) == (user_id, user_id)
    assert await _balance(db_sessionmaker, user_id) == 100
    assert await _pack_owners(db_sessionmaker, lone_pack) == (lone, lone)

    assert await backfill.main(execute=True, confirmed=True) == 0  # nothing left
    assert await _balance(db_sessionmaker, user_id) == 100
