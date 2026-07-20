"""Account/identity domain service for the auth routes (issues #60/#61).

DB-touching transactional logic extracted verbatim from ``app.api.routes.auth``
(backend architecture review 2026-07-18, God-module finding): identity minting
(anon bootstrap), the refresh-time profile read, account resolution, the GDPR
erasure statements, the usage-history read, and the best-effort Apple-grant
revoke. The HTTP route keeps request parsing, auth checks, and orchestration.

Transaction boundaries are unchanged: the bootstrap helpers own their whole
session/commit exactly as they did in the route; ``erase_account`` and the read
helpers run in the caller's session and the caller commits. Error mapping is
preserved exactly, so these helpers raise ``fastapi.HTTPException`` directly.
"""

from __future__ import annotations

import base64
import logging
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from ..db.models import AnonymousIdentity, DailyUsage, RefreshToken, User
from .app_attest import AppAttestError
from .apple_oauth import AppleOAuthClient, AppleOAuthError
from .apple_secrets import AppleTokenCipher
from .identity import AuthSubject

logger = logging.getLogger(__name__)


async def bootstrap_plain(sessionmaker, refresh_store) -> tuple[str, str]:
    """Mint a fresh identity with no App Attest gate (Part A behaviour)."""
    anon_id = str(uuid.uuid4())
    async with sessionmaker() as session:
        session.add(AnonymousIdentity(anon_id=anon_id))
        issued = await refresh_store.issue(session, anon_id)
        await session.commit()
    logger.info("Anon bootstrap: minted identity %s (unattested)", anon_id)
    return anon_id, issued.raw_token


async def bootstrap_with_attestation(
    attest_service, sessionmaker, refresh_store, body
) -> tuple[str, str]:
    """First launch: verify the attestation, mint the identity, and bind the key
    to it — identity row, key binding, and first refresh token in one commit."""
    try:
        attestation = base64.b64decode(body.attestation)
    except Exception:
        raise HTTPException(status_code=400, detail="Malformed attestation")

    async with sessionmaker() as session:
        try:
            key = await attest_service.verify_attestation(
                body.key_id, attestation, body.challenge, session=session
            )
        except AppAttestError:
            # Never leak which check failed (challenge/cert/nonce/env/keyId).
            raise HTTPException(status_code=401, detail="Attestation rejected")
        if key.anon_id is not None:
            # The key was attested and bound before (client retry after a crash
            # mid-bootstrap): honour the existing 1:1 binding — re-issue for the
            # bound identity instead of minting a second one for the same key.
            anon_id = key.anon_id
        else:
            anon_id = str(uuid.uuid4())
            key.anon_id = anon_id
            session.add(AnonymousIdentity(anon_id=anon_id))
        issued = await refresh_store.issue(session, anon_id)
        await session.commit()

    logger.info("Anon bootstrap: minted identity %s (attested)", anon_id)
    return anon_id, issued.raw_token


async def bootstrap_with_assertion(
    attest_service, sessionmaker, refresh_store, body
) -> tuple[str, str]:
    """Re-bootstrap: verify the assertion against the stored key (advancing its
    counter) and re-issue tokens for the identity that key is already bound to."""
    try:
        assertion = base64.b64decode(body.assertion)
    except Exception:
        raise HTTPException(status_code=400, detail="Malformed assertion")

    try:
        key = await attest_service.verify_assertion(
            body.key_id, assertion, body.challenge
        )
    except AppAttestError:
        raise HTTPException(status_code=401, detail="Assertion rejected")

    if key.anon_id is None:
        # Attested key that was never bound to an identity — nothing to re-issue.
        raise HTTPException(status_code=401, detail="Assertion rejected")

    anon_id = key.anon_id
    async with sessionmaker() as session:
        issued = await refresh_store.issue(session, anon_id)
        await session.commit()

    logger.info("Anon bootstrap: re-issued identity %s (assertion)", anon_id)
    return anon_id, issued.raw_token


async def user_profile_fields(
    sessionmaker, subject_id: str
) -> tuple[Optional[str], Optional[str]]:
    """The stored ``(full_name, email)`` for a token subject, or ``(None, None)``.

    #78: an Apple-upgraded account's subject is users.id — round-trip its
    full_name/email on refresh too, or a signed-in user's stored name silently
    disappears client-side on every routine refresh (~900s), not just on
    sign-out/re-sign-in. Plain anon subjects are also UUIDs, so the lookup
    runs for them too and simply finds no row; the parse guard only filters
    legacy non-UUID device ids."""
    full_name: Optional[str] = None
    email: Optional[str] = None
    try:
        user_uuid = uuid.UUID(subject_id)
    except ValueError:
        user_uuid = None
    if user_uuid is not None:
        async with sessionmaker() as session:
            user = (
                await session.execute(select(User).where(User.id == user_uuid))
            ).scalar_one_or_none()
        if user is not None:
            full_name = user.full_name
            email = user.email
    return full_name, email


async def resolve_account(subject: AuthSubject, session: AsyncSession) -> User:
    """Resolve an authenticated subject to its ``users`` row, or reject.

    The account endpoints act on a real account, so the bearer's subject must be a
    ``users.id`` (minted by Sign in with Apple). A missing/invalid bearer is 401; an
    *authenticated* anonymous or legacy subject simply has no account → 404 (it is
    asking about itself, so distinguishing the two leaks nothing)."""
    if not subject.authenticated or not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    try:
        user_id = uuid.UUID(subject.subject_id)
    except ValueError:
        # A non-UUID subject (e.g. a legacy ``dev_…`` id) is never a users.id.
        raise HTTPException(status_code=404, detail="Account not found")
    user = (
        await session.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="Account not found")
    return user


async def erase_account(session: AsyncSession, user: User) -> None:
    """Erase the account's local data in the caller's transaction (GDPR Art. 17).

    The ``users`` row, its ``daily_usage`` (keyed on ``subject_id`` == ``users.id``)
    and its ``refresh_tokens`` (filtered on ``anon_id`` == ``users.id`` — migration
    0004 dropped the cascade, so these go explicitly). The merged anonymous trail
    is de-linked by nulling ``upgraded_to_user_id``; the leftover anon row is then
    an unlinked random id (not personal data) and, unlike deleting it, the
    device's App Attest key binding is left intact. The caller commits."""
    user_id = str(user.id)
    await _preserve_todays_count_on_anons(session, user_id)
    await session.execute(delete(DailyUsage).where(DailyUsage.subject_id == user_id))
    await session.execute(delete(RefreshToken).where(RefreshToken.anon_id == user_id))
    await session.execute(
        update(AnonymousIdentity)
        .where(AnonymousIdentity.upgraded_to_user_id == user_id)
        .values(upgraded_to_user_id=None)
    )
    await session.execute(delete(User).where(User.id == user.id))


async def _preserve_todays_count_on_anons(session: AsyncSession, user_id: str) -> None:
    """Carry the account's *today* question count back onto its linked anonymous
    identities before the GDPR erasure drops the account's usage rows.

    Anti-abuse guard: the device's App Attest key stays bound to its anon, so
    after the delete the very next bootstrap returns the device to that subject —
    if today's count died with the account, delete→re-bootstrap would be a free
    daily-limit reset, repeatable every day. Only today's counter is kept
    (GREATEST, so it can only tighten), on ids that are random and, after the
    de-link below, no longer connected to the person — GDPR-minimal fraud
    prevention, not retained account data. ``is_premium`` is deliberately NOT
    carried over: the entitlement dies with the account."""
    today = datetime.now(timezone.utc).date()
    today_row = (
        await session.execute(
            select(DailyUsage).where(
                DailyUsage.subject_id == user_id,
                DailyUsage.usage_date == today,
            )
        )
    ).scalar_one_or_none()
    if today_row is None or today_row.questions_count <= 0:
        return
    anon_ids = (
        (
            await session.execute(
                select(AnonymousIdentity.anon_id).where(
                    AnonymousIdentity.upgraded_to_user_id == user_id
                )
            )
        )
        .scalars()
        .all()
    )
    for anon_id in anon_ids:
        await session.execute(
            pg_insert(DailyUsage)
            .values(
                subject_id=anon_id,
                usage_date=today,
                questions_count=today_row.questions_count,
                is_premium=False,
            )
            .on_conflict_do_update(
                index_elements=["subject_id", "usage_date"],
                set_={
                    "questions_count": func.greatest(
                        DailyUsage.questions_count, today_row.questions_count
                    )
                },
            )
        )


async def usage_history(session: AsyncSession, subject_id: str) -> list[DailyUsage]:
    """The account's full per-day usage rows, oldest first (GDPR Art. 20 export)."""
    return list(
        (
            await session.execute(
                select(DailyUsage)
                .where(DailyUsage.subject_id == subject_id)
                .order_by(DailyUsage.usage_date)
            )
        )
        .scalars()
        .all()
    )


async def revoke_apple_grant(
    oauth_client: Optional[AppleOAuthClient],
    cipher: Optional[AppleTokenCipher],
    encrypted: Optional[bytes],
    user_id: str,
) -> None:
    """Best-effort Apple token revoke for a just-deleted account (F4).

    Never raises: the GDPR delete already committed, so neither a missing refresh
    token, an unconfigured client, a decrypt error, nor an Apple outage may undo it.
    Every non-revoke is logged loudly rather than swallowed silently."""
    if encrypted is None:
        # Apple did not return a refresh token at sign-in, and /auth/revoke requires
        # a token — there is nothing to revoke. The no-token path (F10): skip + log.
        logger.info(
            "Account %s had no stored Apple refresh token — skipping revoke "
            "(no-token, F10).",
            user_id,
        )
        return
    if oauth_client is None or cipher is None:
        logger.warning(
            "Apple revoke unavailable (client/cipher unconfigured) for deleted "
            "account %s — local delete stands (F4).",
            user_id,
        )
        return
    try:
        await oauth_client.revoke(cipher.decrypt(encrypted))
        logger.info("Revoked Apple grant for deleted account %s.", user_id)
    except AppleOAuthError:
        logger.warning(
            "Apple revoke failed for deleted account %s — local delete stands (F4).",
            user_id,
        )
    except Exception:  # decrypt error, etc. — must never reverse the GDPR delete
        logger.exception(
            "Unexpected error revoking Apple grant for deleted account %s — local "
            "delete stands (F4).",
            user_id,
        )
