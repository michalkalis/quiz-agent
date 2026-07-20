"""Anonymous→account fold for Sign in with Apple (decision F3, issues #61/#93).

Sibling to ``rc_service`` — the sign-in-side counterpart of the webhook-side
subscription/credit writes. Extracted verbatim from ``app.api.routes.auth``
(backend architecture review 2026-07-18): the ``users`` upsert, the row-locked
identity merge (usage summing, subscription/credit folding), and its
pre-exchange 409 check. All helpers run in the caller's session/transaction —
the sign-in route owns the commit. Error mapping is preserved exactly as it was
in the route layer, so the merge guards raise ``fastapi.HTTPException`` (409).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..db.models import (
    AnonymousIdentity,
    CreditLedger,
    DailyUsage,
    RefreshToken,
    Subscription,
    User,
)
from .subscription_state import SubscriptionState, merge_subscription_rows


async def precheck_merge_conflict(
    session: AsyncSession, anon_id: str, apple_sub: str
) -> None:
    """Raise the merge 409 before Apple's single-use code is exchanged (#91 item 5).

    An unlocked read answering the same question as merge_anonymous_identity's
    guard, from data available before the exchange: the anon is already upgraded
    to some account, and this apple_sub is not it (a first-time apple_sub can
    never match a pre-existing upgrade). The locked check downstream stays
    authoritative — a race between this read and the transaction is still caught
    there, at the same one-time-code cost as today."""
    anon = (
        await session.execute(
            select(AnonymousIdentity).where(AnonymousIdentity.anon_id == anon_id)
        )
    ).scalar_one_or_none()
    if anon is None or anon.upgraded_to_user_id is None:
        return
    user = (
        await session.execute(select(User).where(User.apple_sub == apple_sub))
    ).scalar_one_or_none()
    if user is not None and str(user.id) == str(anon.upgraded_to_user_id):
        return  # already folded into this same account — the idempotent path
    raise HTTPException(
        status_code=409,
        detail="This anonymous identity already belongs to another account",
    )


async def upsert_apple_user(
    session: AsyncSession,
    *,
    apple_sub: str,
    email: Optional[str],
    full_name: Optional[str],
    encrypted_refresh: Optional[bytes],
) -> User:
    """Find the account for ``apple_sub`` or create it.

    Apple sends email/name only on first authorization, so they are written once
    and never clobbered by a later null (the user may also hide their email); the
    encrypted Apple refresh token is refreshed whenever Apple returns a new one."""
    user = (
        await session.execute(select(User).where(User.apple_sub == apple_sub))
    ).scalar_one_or_none()
    if user is None:
        try:
            # Savepoint: two concurrent first sign-ins for the same apple_sub can
            # both pass the None-check and race on the UNIQUE(apple_sub) insert —
            # the loser re-reads the winner's row (and falls through to the
            # update-fields path below) instead of surfacing a 500.
            async with session.begin_nested():
                user = User(
                    apple_sub=apple_sub,
                    email=email,
                    full_name=full_name,
                    apple_refresh_token_encrypted=encrypted_refresh,
                )
                session.add(user)
                await session.flush()  # populate user.id for merge + token issue
            return user
        except IntegrityError:
            user = (
                await session.execute(select(User).where(User.apple_sub == apple_sub))
            ).scalar_one()
    if encrypted_refresh is not None:
        user.apple_refresh_token_encrypted = encrypted_refresh
    if email and not user.email:
        user.email = email
    if full_name and not user.full_name:
        user.full_name = full_name
    return user


async def merge_anonymous_identity(
    session: AsyncSession, anon_id: str, user_id: str
) -> None:
    """Fold an anonymous identity's usage into the account, exactly once (F3).

    Guarded by ``anonymous_identities.upgraded_to_user_id``: already this user →
    idempotent no-op; a different user → 409 (the anon belongs elsewhere). The
    anon's ``daily_usage`` rows (keyed on ``subject_id``) are **summed** into the
    account's rows (``is_premium`` OR-ed) — sum, not max, so signing in cannot
    reset the freemium limit. The anon's own rows are **kept** (frozen — nothing
    increments them while the device holds a user-subject bearer): the device's
    App Attest key stays bound to this anon for life, so sign-out or account
    deletion returns the device to this subject — if its counters were dropped
    here, that return trip would be a free daily-limit reset. The anon's
    still-live refresh tokens are revoked so the upgraded identity cannot keep
    minting anon access tokens against a separate usage bucket. Row-locked to
    serialise concurrent sign-ins on the same anon."""
    anon = (
        await session.execute(
            select(AnonymousIdentity)
            .where(AnonymousIdentity.anon_id == anon_id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if anon is None:
        return  # bearer named a subject with no identity row — nothing to merge
    if anon.upgraded_to_user_id is not None:
        if anon.upgraded_to_user_id == user_id:
            return  # already folded into this account — idempotent
        raise HTTPException(
            status_code=409,
            detail="This anonymous identity already belongs to another account",
        )

    anon_rows = (
        (
            await session.execute(
                select(DailyUsage).where(DailyUsage.subject_id == anon_id)
            )
        )
        .scalars()
        .all()
    )
    for row in anon_rows:
        existing = (
            await session.execute(
                select(DailyUsage).where(
                    DailyUsage.subject_id == user_id,
                    DailyUsage.usage_date == row.usage_date,
                )
            )
        ).scalar_one_or_none()
        if existing is None:
            session.add(
                DailyUsage(
                    subject_id=user_id,
                    usage_date=row.usage_date,
                    questions_count=row.questions_count,
                    is_premium=row.is_premium,
                )
            )
        else:
            existing.questions_count += row.questions_count  # SUM (F3, not max)
            existing.is_premium = existing.is_premium or row.is_premium  # OR (F3)

    await _fold_subscription(session, anon_id, user_id)
    await _fold_credit_ledger(session, anon_id, user_id)

    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.anon_id == anon_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=datetime.now(timezone.utc))
    )

    anon.upgraded_to_user_id = user_id


def _sub_state(row: Subscription) -> SubscriptionState:
    return SubscriptionState(
        product_id=row.product_id,
        status=row.status,
        expires_at=row.expires_at,
        rc_original_txn_id=row.rc_original_txn_id,
        last_event_ts_ms=row.last_event_ts_ms,
        environment=row.environment,
    )


async def _fold_subscription(session: AsyncSession, anon_id: str, user_id: str) -> None:
    """Re-key the anon's ``subscription`` row onto the durable user account (#93).

    ``subscription.account_id`` is PK/UNIQUE, so a naive re-key UPDATE would abort
    on the UNIQUE constraint whenever a user-keyed row already exists (sub on
    device A while signed in + anon restore on device B → two rows for one
    account at sign-in). The fold therefore resolves both rows **into the
    user-keyed row via the shared ``merge_subscription_rows`` helper** — same
    rules the webhook uses (row-wise max-wins on ``expires_at``, status
    precedence on ties, field-max ``last_event_ts_ms``; winner taken WHOLESALE,
    never a synthesized ``{status, expires_at}`` combo) — then deletes the anon
    row, all inside the sign-in transaction so it can never leave two rows or
    abort. When only the anon row exists it degrades to a plain re-key UPDATE."""
    anon_row = (
        await session.execute(
            select(Subscription).where(Subscription.account_id == anon_id)
        )
    ).scalar_one_or_none()
    if anon_row is None:
        return  # nothing bought while anonymous

    user_row = (
        await session.execute(
            select(Subscription).where(Subscription.account_id == user_id)
        )
    ).scalar_one_or_none()
    if user_row is None:
        # Common case: only the anon row exists — plain re-key.
        anon_row.account_id = user_id
        return

    # Both rows exist — merge wholesale into the user-keyed row, drop the anon row.
    winner = merge_subscription_rows(_sub_state(anon_row), _sub_state(user_row))
    user_row.product_id = winner.product_id
    user_row.status = winner.status
    user_row.expires_at = winner.expires_at
    user_row.rc_original_txn_id = winner.rc_original_txn_id
    user_row.last_event_ts_ms = winner.last_event_ts_ms
    # #101: the environment stamp is part of the wholesale winner row — leaving
    # the loser's stamp would let a stale/NULL row defeat the entitlement gate.
    user_row.environment = winner.environment
    await session.delete(anon_row)


async def _fold_credit_ledger(
    session: AsyncSession, anon_id: str, user_id: str
) -> None:
    """Bare re-key of the anon's ``credit_ledger`` rows onto the user account (#93).

    Collision-free by construction: the grant/clawback unique indexes are
    **global** on the store/event ids (not per-account) and the ledger is
    append-only, so rewriting ``account_id`` can never violate a uniqueness
    constraint — and a post-sign-in webhook for the same txn still no-ops on the
    global grant index (no double-grant)."""
    await session.execute(
        update(CreditLedger)
        .where(CreditLedger.account_id == anon_id)
        .values(account_id=user_id)
    )
    # TODO(#93): call RC logIn/alias so RevenueCat's own history merges onto the
    # durable user id. Deferred: no RC client wrapper exists on the backend
    # (only the REST GET fetch_rc_subscriber), and adding a live RC call on the
    # sign-in hot path needs a clear existing pattern.
