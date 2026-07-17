"""Anonymous-identity auth endpoints (issue #60, task 60.4).

Two endpoints back the server-trusted identity model:

- ``POST /auth/anon-bootstrap`` — first launch: create an ``anonymous_identities``
  row and hand back an access JWT + an opaque refresh token. The only Part A
  abuse gate is an IP rate-limit keyed on the *real* client IP (decision D6);
  the App Attest gate is added in Part B.
- ``POST /auth/refresh`` — rotate the refresh token (decision D5). On any
  verification failure — including replay of an already-used token (which also
  revokes the whole family) — we return 401 so the client re-bootstraps.
"""

from __future__ import annotations

import base64
import logging
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import (
    AccountExportResponse,
    AccountUsageRecord,
    AnonBootstrapRequest,
    AppleSignInRequest,
    AttestChallengeResponse,
    AuthTokenResponse,
    RefreshRequest,
    get_app_attest_service,
    get_apple_oauth_client,
    get_apple_token_cipher,
    get_apple_verifier,
    get_auth_sessionmaker,
    get_challenge_store,
    get_refresh_store,
    get_token_service,
    require_auth_or_grace,
)
from ...auth.app_attest import AppAttestError, AppAttestService
from ...auth.apple import AppleIdentityVerifier, AppleVerificationError
from ...auth.apple_oauth import AppleOAuthClient, AppleOAuthError
from ...auth.apple_secrets import AppleTokenCipher
from ...auth.attest_challenge import ChallengeStore
from ...auth.identity import AuthSubject
from ...auth.refresh import RefreshError, RefreshTokenStore
from ...auth.tokens import TokenError, TokenService
from ...config import get_settings
from ...db.models import (
    AnonymousIdentity,
    CreditLedger,
    DailyUsage,
    RefreshToken,
    Subscription,
    User,
)
from ...rate_limit import fly_client_ip, limiter
from ...usage.subscription_state import SubscriptionState, merge_subscription_rows

logger = logging.getLogger(__name__)
router = APIRouter()

# Coarse backstop only — App Attest (Part B) is the real anti-abuse lock. Kept
# generous because household NAT shares one IP across devices, and a failed
# refresh re-bootstraps through here too.
_BOOTSTRAP_RATE = "20/minute"


@router.post("/auth/anon-bootstrap", response_model=AuthTokenResponse)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def anon_bootstrap(
    request: Request,
    body: Optional[AnonBootstrapRequest] = None,
    token_service: TokenService = Depends(get_token_service),
    refresh_store: RefreshTokenStore = Depends(get_refresh_store),
    sessionmaker=Depends(get_auth_sessionmaker),
    attest_service: Optional[AppAttestService] = Depends(get_app_attest_service),
) -> AuthTokenResponse:
    """Mint (or re-issue) an anonymous identity + token pair.

    Three mutually-exclusive paths, decided by the credentials the device sends
    and the ``APP_ATTEST_REQUIRED`` flag (#60.12):

    - **attestation** (first launch) → verify, mint a new identity, bind this
      Secure-Enclave key to it 1:1, issue tokens — all in one transaction.
    - **assertion** (re-bootstrap) → verify against the stored key, re-issue
      tokens for the *already-bound* identity. Never mints a new one, so one
      device key maps to exactly one identity for its lifetime.
    - **plain** (flag off / empty body) → mint as in Part A. Rejected with 401
      when ``APP_ATTEST_REQUIRED`` is on and no valid credential is supplied.
    """
    if token_service is None or refresh_store is None or sessionmaker is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    body = body or AnonBootstrapRequest()
    required = get_settings().app_attest_required

    if required and attest_service is None:
        # Gate demanded but the verifier is unconfigured (no APP_ATTEST_APP_ID).
        # Fail safe — never fall back to minting unattested identities in prod.
        raise HTTPException(status_code=503, detail="Auth unavailable")

    has_keyed_challenge = bool(body.key_id and body.challenge)
    use_attestation = bool(body.attestation) and has_keyed_challenge
    use_assertion = bool(body.assertion) and has_keyed_challenge

    if attest_service is not None and use_attestation:
        anon_id, refresh_token = await _bootstrap_with_attestation(
            attest_service, sessionmaker, refresh_store, body
        )
    elif attest_service is not None and use_assertion:
        anon_id, refresh_token = await _bootstrap_with_assertion(
            attest_service, sessionmaker, refresh_store, body
        )
    elif required:
        # Flag on but no usable attestation/assertion → reject (the whole point).
        raise HTTPException(status_code=401, detail="App Attest required")
    else:
        anon_id, refresh_token = await _bootstrap_plain(sessionmaker, refresh_store)

    access_token = token_service.create_access_token(anon_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=token_service.access_ttl_seconds,
        anon_id=anon_id,
    )


async def _bootstrap_plain(sessionmaker, refresh_store) -> tuple[str, str]:
    """Mint a fresh identity with no App Attest gate (Part A behaviour)."""
    anon_id = str(uuid.uuid4())
    async with sessionmaker() as session:
        session.add(AnonymousIdentity(anon_id=anon_id))
        issued = await refresh_store.issue(session, anon_id)
        await session.commit()
    logger.info("Anon bootstrap: minted identity %s (unattested)", anon_id)
    return anon_id, issued.raw_token


async def _bootstrap_with_attestation(
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


async def _bootstrap_with_assertion(
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


@router.post("/auth/attest-challenge", response_model=AttestChallengeResponse)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def attest_challenge(
    request: Request,
    challenge_store: ChallengeStore = Depends(get_challenge_store),
) -> AttestChallengeResponse:
    """Hand the device a fresh single-use challenge for App Attest (Part B).

    The device signs over this value when attesting a key or producing an
    assertion, so it cannot precompute or replay a signature. Returns 503 when
    App Attest is unconfigured (no DB), matching the other auth endpoints.
    """
    if challenge_store is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    challenge = await challenge_store.issue()
    return AttestChallengeResponse(
        challenge=challenge,
        expires_in=challenge_store.ttl_seconds,
    )


@router.post("/auth/refresh", response_model=AuthTokenResponse)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def refresh(
    request: Request,
    body: RefreshRequest,
    token_service: TokenService = Depends(get_token_service),
    refresh_store: RefreshTokenStore = Depends(get_refresh_store),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> AuthTokenResponse:
    """Rotate a refresh token, returning a new access + refresh pair."""
    if token_service is None or refresh_store is None or sessionmaker is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    try:
        result = await refresh_store.rotate(body.refresh_token)
    except RefreshError:
        # Covers unknown/expired/revoked tokens *and* reuse (family already
        # revoked inside rotate()). The client reacts identically: re-bootstrap.
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    access_token = token_service.create_access_token(result.anon_id)

    # #78: an Apple-upgraded account's subject is users.id — round-trip its
    # full_name/email here too, or a signed-in user's stored name silently
    # disappears client-side on every routine refresh (~900s), not just on
    # sign-out/re-sign-in. Plain anon subjects are also UUIDs, so the lookup
    # runs for them too and simply finds no row; the parse guard only filters
    # legacy non-UUID device ids.
    full_name: Optional[str] = None
    email: Optional[str] = None
    try:
        user_uuid = uuid.UUID(result.anon_id)
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

    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=result.refresh.raw_token,
        expires_in=token_service.access_ttl_seconds,
        anon_id=result.anon_id,
        full_name=full_name,
        email=email,
    )


@router.post("/auth/logout", status_code=204)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def logout(
    request: Request,
    body: RefreshRequest,
    refresh_store: RefreshTokenStore = Depends(get_refresh_store),
) -> Response:
    """Revoke the presented refresh token's whole family (sign-out).

    Without this, a client-side sign-out leaves the last refresh token valid on
    the server for its full TTL — anyone who extracted it could keep minting
    sessions after the user believed they signed out. Always 204: idempotent,
    and the response never reveals whether the token was valid."""
    if refresh_store is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    await refresh_store.revoke_family(body.refresh_token)
    return Response(status_code=204)


@router.post("/auth/apple", response_model=AuthTokenResponse)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def apple_sign_in(
    request: Request,
    body: AppleSignInRequest,
    token_service: TokenService = Depends(get_token_service),
    refresh_store: RefreshTokenStore = Depends(get_refresh_store),
    sessionmaker=Depends(get_auth_sessionmaker),
    verifier: Optional[AppleIdentityVerifier] = Depends(get_apple_verifier),
    oauth_client: Optional[AppleOAuthClient] = Depends(get_apple_oauth_client),
    cipher: Optional[AppleTokenCipher] = Depends(get_apple_token_cipher),
) -> AuthTokenResponse:
    """Upgrade an anonymous identity to a real account via Sign in with Apple.

    Verifies the Apple identity token, exchanges the authorization code for
    Apple's refresh token, upserts the ``users`` row keyed on ``apple_sub``, folds
    the caller's anonymous usage into the account (decision F3), stores Apple's
    refresh token encrypted (F1/F2), and issues *our* access + refresh pair whose
    subject is ``users.id`` — all in one DB transaction.

    F7: this endpoint is deliberately **not** behind App Attest — a verified Apple
    identity token is itself a strong barrier (unlike anon-bootstrap, which is
    attested precisely because it has no such external proof of authenticity).
    """
    if (
        token_service is None
        or refresh_store is None
        or sessionmaker is None
        or verifier is None
        or oauth_client is None
        or cipher is None
    ):
        raise HTTPException(status_code=503, detail="Sign in with Apple unavailable")

    # 1) Inbound trust boundary: prove the id_token is Apple's, minted for our app,
    #    for this very sign-in attempt (nonce, F6). Never leak which check failed.
    try:
        claims = await verifier.verify(body.identity_token, raw_nonce=body.raw_nonce)
    except AppleVerificationError:
        raise HTTPException(status_code=401, detail="Invalid Apple identity token")
    apple_sub = claims.get("sub")
    if not apple_sub:
        raise HTTPException(status_code=401, detail="Invalid Apple identity token")

    # The anon to fold in is named by the *current* bearer's subject (stale-but-ours
    # still counts — see TokenService.subject_from_token). The Apple token, not this
    # bearer, authorizes the call (F7), so a missing/foreign bearer is not fatal —
    # there is simply nothing to merge.
    anon_id = _anon_subject_for_merge(request, token_service)

    # 2) Pre-check the merge conflict BEFORE the code exchange (#91 item 5): the
    #    409 below in _merge_anonymous_identity is deterministic — no retry can
    #    ever succeed — so raising it only after the exchange burns a single-use
    #    Apple code per attempt for a guaranteed failure. Everything the check
    #    needs (anon row + apple_sub) is already available here.
    if anon_id is not None:
        async with sessionmaker() as session:
            await _precheck_merge_conflict(session, anon_id, apple_sub)

    # 3) Exchange the authorization code immediately — Apple voids it after ~5 min
    #    (F10). Capture Apple's refresh token (it is not always present).
    try:
        exchange = await oauth_client.exchange_authorization_code(
            body.authorization_code
        )
    except AppleOAuthError:
        raise HTTPException(status_code=502, detail="Apple token exchange failed")

    # email: trust the verified id_token claim over the client-supplied body.
    email = claims.get("email") or (body.user.email if body.user else None)
    full_name = body.user.name if body.user else None
    encrypted = (
        cipher.encrypt(exchange.refresh_token) if exchange.refresh_token else None
    )

    async with sessionmaker() as session:
        user = await _upsert_apple_user(
            session,
            apple_sub=apple_sub,
            email=email,
            full_name=full_name,
            encrypted_refresh=encrypted,
        )
        user_id = str(user.id)
        if anon_id is not None and anon_id != user_id:
            await _merge_anonymous_identity(session, anon_id, user_id)
        issued = await refresh_store.issue(session, user_id)
        await session.commit()

    access_token = token_service.create_access_token(user_id)
    logger.info("Apple sign-in: account %s (folded anon=%s)", user_id, anon_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=issued.raw_token,
        expires_in=token_service.access_ttl_seconds,
        anon_id=user_id,  # subject is now users.id (field name is legacy)
        # #78: read from the persisted user row, not the local full_name/email
        # request variables — a re-sign-in's body carries no name (Apple only
        # sends it once), but the row still holds it from the first sign-in.
        full_name=user.full_name,
        email=user.email,
    )


def _anon_subject_for_merge(
    request: Request, token_service: TokenService
) -> Optional[str]:
    """The anonymous subject to fold into the account, from the caller's bearer.

    Returns None when there is no bearer, or it is not one of our tokens (then
    there is nothing to merge — the account is still created). Accepts an *expired*
    anon access token on purpose: it still authentically names the anon, and
    folding its usage is what stops a freemium reset by letting the token lapse
    before upgrading (F3)."""
    header = request.headers.get("Authorization")
    if not header:
        return None
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    try:
        return token_service.subject_from_token(token.strip(), allow_expired=True)
    except TokenError:
        return None


async def _precheck_merge_conflict(
    session: AsyncSession, anon_id: str, apple_sub: str
) -> None:
    """Raise the merge 409 before Apple's single-use code is exchanged (#91 item 5).

    An unlocked read answering the same question as _merge_anonymous_identity's
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


async def _upsert_apple_user(
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


async def _merge_anonymous_identity(
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


@router.delete("/auth/me", status_code=204)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def delete_account(
    request: Request,
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
    oauth_client: Optional[AppleOAuthClient] = Depends(get_apple_oauth_client),
    cipher: Optional[AppleTokenCipher] = Depends(get_apple_token_cipher),
) -> Response:
    """Delete the caller's account and all its data (GDPR Art. 17), then sever the
    Apple grant.

    The local erasure is one transaction: the ``users`` row, its ``daily_usage``
    (keyed on ``subject_id`` == ``users.id``) and its ``refresh_tokens`` (filtered
    on ``anon_id`` == ``users.id`` — migration 0004 dropped the cascade, so these
    go explicitly). The merged anonymous trail is de-linked by nulling
    ``upgraded_to_user_id``; the leftover anon row is then an unlinked random id
    (not personal data) and, unlike deleting it, the device's App Attest key
    binding is left intact.

    F4: the Apple revoke runs *after* the local delete commits and is best-effort —
    a missing refresh token or an Apple outage never blocks or reverses the erasure.
    """
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    async with sessionmaker() as session:
        user = await _resolve_account(subject, session)
        user_id = str(user.id)
        encrypted = user.apple_refresh_token_encrypted

        await _preserve_todays_count_on_anons(session, user_id)
        await session.execute(
            delete(DailyUsage).where(DailyUsage.subject_id == user_id)
        )
        await session.execute(
            delete(RefreshToken).where(RefreshToken.anon_id == user_id)
        )
        await session.execute(
            update(AnonymousIdentity)
            .where(AnonymousIdentity.upgraded_to_user_id == user_id)
            .values(upgraded_to_user_id=None)
        )
        await session.execute(delete(User).where(User.id == user.id))
        await session.commit()

    await _revoke_apple_grant(oauth_client, cipher, encrypted, user_id)
    logger.info("Account %s deleted (GDPR erasure).", user_id)
    return Response(status_code=204)


@router.get("/auth/me/export", response_model=AccountExportResponse)
@limiter.limit(_BOOTSTRAP_RATE, key_func=fly_client_ip)
async def export_account(
    request: Request,
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> AccountExportResponse:
    """Return the caller's account data as JSON (GDPR Art. 20 portability).

    Profile + full per-day usage history + derived premium. Never includes the
    encrypted Apple refresh token or any other secret (the response model has no
    field for one)."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    async with sessionmaker() as session:
        user = await _resolve_account(subject, session)
        rows = (
            (
                await session.execute(
                    select(DailyUsage)
                    .where(DailyUsage.subject_id == str(user.id))
                    .order_by(DailyUsage.usage_date)
                )
            )
            .scalars()
            .all()
        )

    today = datetime.now(timezone.utc).date()
    is_premium = any(row.is_premium for row in rows if row.usage_date == today)
    return AccountExportResponse(
        apple_sub=user.apple_sub,
        email=user.email,
        full_name=user.full_name,
        created_at=user.created_at,
        is_premium=is_premium,
        usage=[
            AccountUsageRecord(
                usage_date=row.usage_date,
                questions_count=row.questions_count,
                is_premium=row.is_premium,
            )
            for row in rows
        ],
    )


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


async def _resolve_account(subject: AuthSubject, session: AsyncSession) -> User:
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


async def _revoke_apple_grant(
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
