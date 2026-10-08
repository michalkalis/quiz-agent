"""``DELETE /auth/me`` reaches the anonymous trail (#193 — beta hardening, task 193.8).

Every user has a server-side anonymous identity from first launch, and sign-in
does not re-key feedback, analytics, pack orders or quiz sessions onto the
account. So:

- deleting an account must also erase what the person produced *before* signing
  in, under the anon ids linked to it — de-linking alone leaves their
  screenshots, dictation audio and events behind;
- an anonymous user (the app shows "Delete my data" before sign-in) must get a
  working erasure too (GDPR Art. 17, App Store 5.1.1(v)), not a 404.

Each test seeds an unrelated subject's data and asserts it survives.
"""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest
from app.db.models import (
    AnalyticsEvent,
    AnonymousIdentity,
    DailyUsage,
    Feedback,
    RefreshToken,
)
from app.session.manager import SessionManager
from app.usage.tracker import _month_start
from quiz_shared.database.sql_client import RatingDB
from sqlalchemy import text

from tests.test_auth_me_endpoints import (
    RevokeRecorder,
    _anon,
    _make_account,
    _make_app,
    _rows,
    _seed_anon_upgraded,
    _seed_refresh,
    _seed_usage,
    _today,
    _token_service,
)
from tests.test_auth_me_erase_unlinks import (
    _delete,
    _order_and_pack,
    _rate,
    _ratings_store,
    _seed_order,
)

pytestmark = pytest.mark.asyncio

OTHER = "someone-else"


async def _seed_trail(db, subject_id: str) -> None:
    async with db() as s:
        s.add(
            Feedback(user_id=subject_id, message="screenshot of my car", audio=b"wav")
        )
        s.add(
            AnalyticsEvent(name="quiz_started", subject_id=subject_id, source="server")
        )
        await s.commit()


async def _subjects_with_trail(db) -> tuple[set, set]:
    feedback = {r.user_id for r in await _rows(db, Feedback)}
    events = {r.subject_id for r in await _rows(db, AnalyticsEvent)}
    return feedback, events


async def _make_anon(db) -> tuple[str, str]:
    anon_id = str(uuid.uuid4())
    async with db() as s:
        s.add(AnonymousIdentity(anon_id=anon_id))
        await s.commit()
    return anon_id, _token_service().create_access_token(anon_id)


async def test_account_delete_erases_feedback_and_events_from_before_sign_in(
    db_sessionmaker,
):
    """Feedback and analytics sent while still anonymous stay keyed on the anon
    id after sign-in; the account erasure must reach them, not just de-link."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.trail")
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    for subject in (user_id, anon_id, OTHER):
        await _seed_trail(db_sessionmaker, subject)

    assert (await _delete(app, bearer)).status_code == 204

    assert await _subjects_with_trail(db_sessionmaker) == ({OTHER}, {OTHER})


async def test_account_delete_unlinks_sessions_and_orders_from_before_sign_in(
    db_sessionmaker, tmp_path
):
    """Quiz sessions, ratings and a pack bought while anonymous must stop pointing
    at the person once the account is erased (rows kept, as for the account's own)."""
    store = _ratings_store(tmp_path)
    manager = SessionManager(sql_client=store)
    app = _make_app(db_sessionmaker)
    app.state.session_manager = manager
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.sess2")
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    session = manager.create_session(user_id=anon_id)
    _rate(store, anon_id, session.session_id)
    _rate(store, OTHER, "other-session")
    order_id = await _seed_order(db_sessionmaker, anon_id, "pre-sign-in pack")
    try:
        assert (await _delete(app, bearer)).status_code == 204

        assert manager.get_session(session.session_id) is None
        db = store._get_session()
        try:
            ratings = {r.session_id: r.user_id for r in db.query(RatingDB).all()}
        finally:
            db.close()
        assert ratings == {session.session_id: None, "other-session": OTHER}
        order, pack = await _order_and_pack(db_sessionmaker, order_id)
        assert order == (None, "pre-sign-in pack") and pack[0] is None
    finally:
        async with db_sessionmaker() as s:
            await s.execute(
                text("DELETE FROM generation_orders WHERE id = :a"), {"a": order_id}
            )
            await s.commit()


async def test_anonymous_user_can_erase_their_data(db_sessionmaker):
    """The app offers "Delete my data" before sign-in, so an anon bearer must get
    a real erasure: personal trail gone, pack order unlinked but kept for refunds,
    refresh tokens dropped. No Apple grant exists, so no revoke is attempted."""
    recorder = RevokeRecorder()
    app = _make_app(db_sessionmaker, recorder=recorder)
    anon_id, bearer = await _make_anon(db_sessionmaker)
    for subject in (anon_id, OTHER):
        await _seed_trail(db_sessionmaker, subject)
        await _seed_refresh(db_sessionmaker, subject)
    order_id = await _seed_order(db_sessionmaker, anon_id, "anon pack")
    try:
        assert (await _delete(app, bearer)).status_code == 204

        assert await _subjects_with_trail(db_sessionmaker) == ({OTHER}, {OTHER})
        tokens = await _rows(db_sessionmaker, RefreshToken)
        assert [t.anon_id for t in tokens] == [OTHER]
        order, _ = await _order_and_pack(db_sessionmaker, order_id)
        assert order == (None, "anon pack")
        assert recorder.calls == []
    finally:
        async with db_sessionmaker() as s:
            await s.execute(
                text("DELETE FROM generation_orders WHERE id = :a"), {"a": order_id}
            )
            await s.commit()


async def test_anonymous_erase_keeps_this_months_quota_counters(db_sessionmaker):
    """The device's App Attest key stays bound to this anon, so the next bootstrap
    returns it here: dropping this month's counters would make erase a free quota
    reset. Older months carry no quota meaning and go with the rest."""
    app = _make_app(db_sessionmaker)
    anon_id, bearer = await _make_anon(db_sessionmaker)
    last_month = _month_start() - timedelta(days=1)
    await _seed_usage(db_sessionmaker, anon_id, 30, day=_today())
    await _seed_usage(db_sessionmaker, anon_id, 12, day=last_month)

    assert (await _delete(app, bearer)).status_code == 204

    rows = await _rows(db_sessionmaker, DailyUsage, DailyUsage.subject_id == anon_id)
    assert [(r.usage_date, r.questions_count) for r in rows] == [(_today(), 30)]
    assert await _anon(db_sessionmaker, anon_id) is not None
