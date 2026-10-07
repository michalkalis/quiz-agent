"""``DELETE /auth/me`` completeness beyond the account tables (GDPR Art. 17,
founder decision 2026-10-07). Extends ``test_auth_me_endpoints``.

The person asked to be forgotten, so:

- in-app feedback (screenshot, dictation audio, logs, free text) is deleted;
- quiz sessions, question ratings and custom pack orders/packs are kept (answers
  feed statistics; an order is the refund/accounting record) but no longer point
  at the person, and the free-text pack topic is scrubbed;
- purchase records (``subscription``, ``credit_ledger``) are left untouched:
  accounting and refund law requires keeping them.

Every test seeds a second account's data and asserts it survives, so an erase
that matched too broadly fails here too. Pack tables are quiz-pack-api's
(alembic-managed co-tenants, applied in CI); rows are cleaned up explicitly
because the ``db_sessionmaker`` fixture only drops quiz-agent's own tables.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from app.auth.account_service import ERASED_PROMPT
from app.db.models import CreditLedger, Feedback, Product, Subscription
from app.session.manager import SessionManager
from quiz_shared.database.sql_client import QuizSessionDB, RatingDB, SQLClient
from quiz_shared.models.rating import QuestionRating
from sqlalchemy import text

from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _rows,
    _user_exists,
)

pytestmark = pytest.mark.asyncio

OTHER = "someone-else"


async def _delete(app, bearer):
    async with _asgi(app) as c:
        return await c.delete("/api/v1/auth/me", headers=_auth(bearer))


async def test_delete_removes_the_accounts_in_app_feedback(db_sessionmaker):
    """Feedback carries a screenshot, raw dictation audio, log tail and free text;
    none of it is needed once the person asked to be forgotten, so it goes."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.fb")
    async with db_sessionmaker() as s:
        s.add(Feedback(user_id=user_id, message="my name is Jan", audio=b"wav"))
        s.add(Feedback(user_id=OTHER, message="keep me"))
        await s.commit()

    assert (await _delete(app, bearer)).status_code == 204

    remaining = await _rows(db_sessionmaker, Feedback)
    assert [r.user_id for r in remaining] == [OTHER]


async def _seed_order(db, owner: str, prompt: str) -> uuid.UUID:
    order_id = uuid.uuid4()
    async with db() as s:
        await s.execute(
            text(
                "INSERT INTO generation_orders (id, user_id, transaction_id, "
                "product_id, prompt, target_count, language) VALUES "
                "(:id, :uid, :txn, 'pack_30', :prompt, 30, 'en')"
            ),
            {"id": order_id, "uid": owner, "txn": f"txn-{order_id}", "prompt": prompt},
        )
        await s.execute(
            text(
                "INSERT INTO question_packs (id, order_id, user_id, prompt, "
                "target_count, language) VALUES "
                "(:id, :oid, :uid, :prompt, 30, 'en')"
            ),
            {"id": uuid.uuid4(), "oid": order_id, "uid": owner, "prompt": prompt},
        )
        await s.commit()
    return order_id


async def _order_and_pack(db, order_id: uuid.UUID) -> tuple:
    async with db() as s:
        order = (
            await s.execute(
                text("SELECT user_id, prompt FROM generation_orders WHERE id = :i"),
                {"i": order_id},
            )
        ).one()
        pack = (
            await s.execute(
                text("SELECT user_id, prompt FROM question_packs WHERE order_id = :i"),
                {"i": order_id},
            )
        ).one()
    return tuple(order), tuple(pack)


async def test_delete_unlinks_pack_orders_and_packs_but_keeps_the_rows(
    db_sessionmaker,
):
    """The order row is the refund/accounting record for a paid pack, so it must
    survive; but its owner id and the topic the person typed (which can name
    them) must not. Another account's order stays exactly as it was."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.pack")
    mine = await _seed_order(db_sessionmaker, user_id, "Jan's family trip 2025")
    theirs = await _seed_order(db_sessionmaker, OTHER, "Roman emperors")
    try:
        assert (await _delete(app, bearer)).status_code == 204

        order, pack = await _order_and_pack(db_sessionmaker, mine)
        assert order == (None, ERASED_PROMPT)
        assert pack == (None, ERASED_PROMPT)
        other_order, other_pack = await _order_and_pack(db_sessionmaker, theirs)
        assert other_order == (OTHER, "Roman emperors")
        assert other_pack == (OTHER, "Roman emperors")
    finally:
        async with db_sessionmaker() as s:  # packs cascade with their order
            await s.execute(
                text("DELETE FROM generation_orders WHERE id IN (:a, :b)"),
                {"a": mine, "b": theirs},
            )
            await s.commit()


async def test_delete_keeps_purchase_records_for_accounting(db_sessionmaker):
    """Subscription and credit-ledger rows are legal accounting/refund records;
    the erasure must not touch them."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.buy")
    async with db_sessionmaker() as s:
        s.add(Product(product_id="sub_monthly", kind="subscription", tier="unlimited"))
        await s.flush()
        s.add(
            Subscription(
                account_id=user_id,
                product_id="sub_monthly",
                status="active",
                expires_at=datetime.now(timezone.utc) + timedelta(days=30),
                rc_original_txn_id="otxn-1",
            )
        )
        s.add(
            CreditLedger(
                account_id=user_id,
                delta=100,
                kind="grant",
                reason="pack_100",
                store_txn_id="stxn-1",
            )
        )
        await s.commit()

    assert (await _delete(app, bearer)).status_code == 204

    assert len(await _rows(db_sessionmaker, Subscription)) == 1
    (ledger,) = await _rows(db_sessionmaker, CreditLedger)
    assert (ledger.account_id, ledger.delta) == (user_id, 100)


def _ratings_store(tmp_path) -> SQLClient:
    return SQLClient(database_url=f"sqlite:///{tmp_path}/ratings.db")


def _rate(store: SQLClient, user: str, session_id: str) -> None:
    assert store.add_rating(
        QuestionRating(question_id="q1", session_id=session_id, user_id=user, rating=4)
    )


async def test_delete_unlinks_stored_sessions_and_ratings(db_sessionmaker, tmp_path):
    """Answers and ratings stay for question statistics but must no longer be
    personal: the id disappears from the session JSON (owner, participant and
    the display name that defaults to it) and from the rating. The live session
    is dropped and the stored one deactivated, so an ownerless session can never
    run again (it would skip the quota gates, which key on its owner)."""
    store = _ratings_store(tmp_path)
    manager = SessionManager(sql_client=store)
    app = _make_app(db_sessionmaker)
    app.state.session_manager = manager
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.sess")
    mine = manager.create_session(user_id=user_id)
    theirs = manager.create_session(user_id=OTHER)
    _rate(store, user_id, mine.session_id)
    _rate(store, OTHER, theirs.session_id)

    assert (await _delete(app, bearer)).status_code == 204

    assert manager.get_session(mine.session_id) is None
    assert manager.get_session(theirs.session_id) is not None
    db = store._get_session()
    try:
        row = db.get(QuizSessionDB, mine.session_id)
        assert row is not None and row.is_active is False
        assert user_id not in row.data_json
        data = json.loads(row.data_json)
        assert data["user_id"] is None
        assert data["participants"][0]["user_id"] is None
        assert data["participants"][0]["display_name"] == "Player"
        assert OTHER in db.get(QuizSessionDB, theirs.session_id).data_json
        ratings = {r.session_id: r.user_id for r in db.query(RatingDB).all()}
    finally:
        db.close()
    assert ratings == {mine.session_id: None, theirs.session_id: OTHER}


async def test_delete_aborts_whole_erasure_when_ratings_store_fails(
    db_sessionmaker, tmp_path
):
    """The ratings store cannot share the Postgres transaction, so it is unlinked
    before the commit: if it fails, nothing is committed and the user can retry.
    Committing first would leave sessions linked and a retry would 404."""
    store = _ratings_store(tmp_path)

    def boom(_user_id):
        raise RuntimeError("ratings store down")

    store.unlink_user = boom
    app = _make_app(db_sessionmaker)
    app.state.session_manager = SessionManager(sql_client=store)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.fail")
    async with db_sessionmaker() as s:
        s.add(Feedback(user_id=user_id, message="still here"))
        await s.commit()

    with pytest.raises(RuntimeError, match="ratings store down"):
        await _delete(app, bearer)

    assert await _user_exists(db_sessionmaker, user_id)
    rows = await _rows(db_sessionmaker, Feedback, Feedback.user_id == user_id)
    assert len(rows) == 1
