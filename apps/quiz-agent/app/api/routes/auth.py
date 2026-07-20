"""Anonymous-identity auth endpoints (issue #60, task 60.4).

Two endpoints back the server-trusted identity model:

- ``POST /auth/anon-bootstrap`` — first launch: create an ``anonymous_identities``
  row and hand back an access JWT + an opaque refresh token. The only Part A
  abuse gate is an IP rate-limit keyed on the *real* client IP (decision D6);
  the App Attest gate is added in Part B.
- ``POST /auth/refresh`` — rotate the refresh token (decision D5). On any
  verification failure — including replay of an already-used token (which also
  revokes the whole family) — we return 401 so the client re-bootstraps.

Routes here hold request parsing, auth checks, and orchestration only; the
DB-touching transactional domain logic lives in ``app.auth.account_service``
and ``app.usage.account_merge`` (backend architecture review 2026-07-18).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Response

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
from ...auth.account_service import (
    bootstrap_plain,
    bootstrap_with_assertion,
    bootstrap_with_attestation,
    erase_account,
    resolve_account,
    revoke_apple_grant,
    usage_history,
    user_profile_fields,
)
from ...auth.app_attest import AppAttestService
from ...auth.apple import AppleIdentityVerifier, AppleVerificationError
from ...auth.apple_oauth import AppleOAuthClient, AppleOAuthError
from ...auth.apple_secrets import AppleTokenCipher
from ...auth.attest_challenge import ChallengeStore
from ...auth.identity import AuthSubject
from ...auth.refresh import RefreshError, RefreshTokenStore
from ...auth.tokens import TokenError, TokenService
from ...config import get_settings
from ...rate_limit import fly_client_ip, limiter
from ...usage.account_merge import (
    merge_anonymous_identity,
    precheck_merge_conflict,
    upsert_apple_user,
)

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
        anon_id, refresh_token = await bootstrap_with_attestation(
            attest_service, sessionmaker, refresh_store, body
        )
    elif attest_service is not None and use_assertion:
        anon_id, refresh_token = await bootstrap_with_assertion(
            attest_service, sessionmaker, refresh_store, body
        )
    elif required:
        # Flag on but no usable attestation/assertion → reject (the whole point).
        raise HTTPException(status_code=401, detail="App Attest required")
    else:
        anon_id, refresh_token = await bootstrap_plain(sessionmaker, refresh_store)

    access_token = token_service.create_access_token(anon_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=token_service.access_ttl_seconds,
        anon_id=anon_id,
    )


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

    # #78: round-trip a signed-in user's stored full_name/email on every refresh
    # too — see user_profile_fields for the why.
    full_name, email = await user_profile_fields(sessionmaker, result.anon_id)

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
    #    409 below in merge_anonymous_identity is deterministic — no retry can
    #    ever succeed — so raising it only after the exchange burns a single-use
    #    Apple code per attempt for a guaranteed failure. Everything the check
    #    needs (anon row + apple_sub) is already available here.
    if anon_id is not None:
        async with sessionmaker() as session:
            await precheck_merge_conflict(session, anon_id, apple_sub)

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
        user = await upsert_apple_user(
            session,
            apple_sub=apple_sub,
            email=email,
            full_name=full_name,
            encrypted_refresh=encrypted,
        )
        user_id = str(user.id)
        if anon_id is not None and anon_id != user_id:
            await merge_anonymous_identity(session, anon_id, user_id)
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

    The local erasure is one transaction (see ``erase_account``). F4: the Apple
    revoke runs *after* the local delete commits and is best-effort — a missing
    refresh token or an Apple outage never blocks or reverses the erasure.
    """
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    async with sessionmaker() as session:
        user = await resolve_account(subject, session)
        user_id = str(user.id)
        encrypted = user.apple_refresh_token_encrypted
        await erase_account(session, user)
        await session.commit()

    await revoke_apple_grant(oauth_client, cipher, encrypted, user_id)
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
        user = await resolve_account(subject, session)
        rows = await usage_history(session, str(user.id))

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
