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

import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request

from ..deps import (
    AuthTokenResponse,
    RefreshRequest,
    get_auth_sessionmaker,
    get_refresh_store,
    get_token_service,
)
from ...auth.refresh import RefreshError, RefreshTokenStore
from ...auth.tokens import TokenService
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
    token_service: TokenService = Depends(get_token_service),
    refresh_store: RefreshTokenStore = Depends(get_refresh_store),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> AuthTokenResponse:
    """Mint a fresh anonymous identity + token pair on first launch."""
    if token_service is None or refresh_store is None or sessionmaker is None:
        raise HTTPException(status_code=503, detail="Auth unavailable")

    anon_id = str(uuid.uuid4())
    # Identity row + first refresh token committed atomically.
    async with sessionmaker() as session:
        session.add(AnonymousIdentity(anon_id=anon_id))
        issued = await refresh_store.issue(session, anon_id)
        await session.commit()

    access_token = token_service.create_access_token(anon_id)
    logger.info("Anon bootstrap: minted identity %s", anon_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=issued.raw_token,
        expires_in=token_service.access_ttl_seconds,
        anon_id=anon_id,
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
