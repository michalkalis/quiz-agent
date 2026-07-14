"""``create_session`` pack-ownership gate, pinned against Postgres (#96 review).

A ``pack_id`` both serves private paid questions and bypasses the free quota, so
``_require_pack_ownership`` must accept ONLY the subject that owns the delivered
pack. This runs the real SQL (``question_packs`` matched by ``id`` + ``user_id``)
against the dev-stack Postgres so a wrong column/table — which the unit tests'
fake sessionmaker cannot catch — fails loudly. Skips when ``TEST_DATABASE_URL``
is unset. The ``questions`` schema is alembic-managed by quiz-pack-api and
persistent, so every row created here is cleaned up in ``finally``.
"""

from __future__ import annotations

import os
import uuid

import pytest
import pytest_asyncio
from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.engine import build_engine
from app.api.routes.sessions import _require_pack_ownership


@pytest_asyncio.fixture
async def factory():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed test")
    engine = build_engine(url)
    maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    try:
        yield maker
    finally:
        await engine.dispose()


async def _seed_owned_pack(maker, owner: str) -> tuple[uuid.UUID, uuid.UUID]:
    """Insert generation_orders + question_packs both owned by ``owner``.
    Returns (pack_id, order_id); delete the order to cascade the pack away."""
    order_id, pack_id = uuid.uuid4(), uuid.uuid4()
    async with maker() as s:
        await s.execute(
            text(
                "INSERT INTO generation_orders "
                "(id, transaction_id, product_id, prompt, target_count, language, user_id) "
                "VALUES (:oid, :txn, 'pack_30', 'owntest', 30, 'en', :uid)"
            ),
            {"oid": order_id, "txn": f"owntest-{uuid.uuid4().hex[:10]}", "uid": owner},
        )
        await s.execute(
            text(
                "INSERT INTO question_packs "
                "(id, order_id, prompt, language, target_count, user_id) "
                "VALUES (:pid, :oid, 'owntest', 'en', 30, :uid)"
            ),
            {"pid": pack_id, "oid": order_id, "uid": owner},
        )
        await s.commit()
    return pack_id, order_id


async def _cleanup(maker, order_id: uuid.UUID) -> None:
    async with maker() as s:
        await s.execute(
            text("DELETE FROM generation_orders WHERE id = :oid"), {"oid": order_id}
        )
        await s.commit()


@pytest.mark.asyncio
async def test_owner_passes_non_owner_and_unknown_pack_denied(factory):
    owner = f"owner-{uuid.uuid4().hex[:12]}"
    pack_id, order_id = await _seed_owned_pack(factory, owner)
    try:
        # Owner → allowed (no raise, returns None).
        assert await _require_pack_ownership(str(pack_id), owner, factory) is None

        # A different authenticated subject → IDOR blocked with 404.
        with pytest.raises(HTTPException) as exc:
            await _require_pack_ownership(str(pack_id), "someone-else", factory)
        assert exc.value.status_code == 404

        # A well-formed but unknown pack id → 404 (quota bypass via a fake id blocked).
        with pytest.raises(HTTPException) as exc2:
            await _require_pack_ownership(str(uuid.uuid4()), owner, factory)
        assert exc2.value.status_code == 404
    finally:
        await _cleanup(factory, order_id)
