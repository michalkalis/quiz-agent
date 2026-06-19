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
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request

from ..deps import (
    AnonBootstrapRequest,
    AttestChallengeResponse,
    AuthTokenResponse,
    RefreshRequest,
    get_app_attest_service,
    get_auth_sessionmaker,
    get_challenge_store,
    get_refresh_store,
    get_token_service,
)
from ...auth.app_attest import AppAttestError, AppAttestService
from ...auth.attest_challenge import ChallengeStore
from ...auth.refresh import RefreshError, RefreshTokenStore
from ...auth.tokens import TokenService
from ...config import get_settings
from ...db.models import AnonymousIdentity
from ...rate_limit import fly_client_ip, limiter

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

    anon_id = str(uuid.uuid4())
    async with sessionmaker() as session:
        try:
            key = await attest_service.verify_attestation(
                body.key_id, attestation, body.challenge, session=session
            )
        except AppAttestError:
            # Never leak which check failed (challenge/cert/nonce/env/keyId).
            raise HTTPException(status_code=401, detail="Attestation rejected")
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
async def refresh(
    body: RefreshRequest,
    token_service: TokenService = Depends(get_token_service),
    refresh_store: RefreshTokenStore = Depends(get_refresh_store),
) -> AuthTokenResponse:
    """Rotate a refresh token, returning a new access + refresh pair."""
    if token_service is None or refresh_store is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    try:
        result = await refresh_store.rotate(body.refresh_token)
    except RefreshError:
        # Covers unknown/expired/revoked tokens *and* reuse (family already
        # revoked inside rotate()). The client reacts identically: re-bootstrap.
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    access_token = token_service.create_access_token(result.anon_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=result.refresh.raw_token,
        expires_in=token_service.access_ttl_seconds,
        anon_id=result.anon_id,
    )
