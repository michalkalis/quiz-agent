"""Outbound calls to Apple's OAuth endpoints for Sign in with Apple (issue #61).

The inbound trust boundary lives in ``app.auth.apple`` (verify an id_token); this
is the *outbound* side — we authenticate to Apple with the ES256 client_secret
(``app.auth.apple_secrets``) and call its OAuth endpoints:

- ``exchange_authorization_code`` (61.4, Session B) — trade the single-use
  ``authorization_code`` for Apple's tokens, capturing the **refresh token** we
  store (encrypted) to drive revoke later. Apple voids the code after ~5 min, so
  the route calls this immediately (F10).
- ``revoke`` (61.5, Session C) — revoke a stored Apple refresh token at
  ``/auth/revoke`` when an account is deleted (GDPR). Best-effort: the delete
  route swallows ``AppleOAuthError`` so Apple availability never blocks it (F4).

Both share the client_secret + httpx core (``_post``), which is why this is one
small client and not inline in the route.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

import httpx

from .apple_secrets import generate_client_secret

_APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
# Correct TN3194 slug — the "…-implementing-…" doc variant 404s (F10).
_APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"


class AppleOAuthError(Exception):
    """An outbound call to Apple's OAuth endpoint failed — network error, non-2xx
    response, or a malformed/error body. The token-exchange path maps this to 502;
    the revoke path (Session C) treats it as best-effort (F4)."""


@dataclass(frozen=True)
class AppleTokenExchange:
    """The part of Apple's token response we keep. Apple also returns an
    access_token / id_token, but server-side we only need the refresh token (to
    drive a later revoke) — and Apple does **not** always send one, so it is
    optional (F1: a null refresh token falls back to the no-token revoke)."""

    refresh_token: str | None


class AppleOAuthClient:
    """Calls Apple's OAuth endpoints, authenticating with a freshly-signed ES256
    client_secret per request (cheap; avoids caching/expiry bookkeeping)."""

    def __init__(
        self,
        *,
        team_id: str,
        client_id: str | Sequence[str],
        key_id: str,
        private_key: str,
        http_client: httpx.AsyncClient | None = None,
        token_url: str = _APPLE_TOKEN_URL,
        revoke_url: str = _APPLE_REVOKE_URL,
    ) -> None:
        client_ids = (client_id,) if isinstance(client_id, str) else tuple(client_id)
        if not (team_id and client_ids and all(client_ids) and key_id and private_key):
            raise RuntimeError(
                "Apple Sign in key is not fully configured (need APPLE_SIGNIN_TEAM_ID, "
                "APPLE_SIGNIN_CLIENT_ID, APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_PRIVATE_KEY)."
            )
        self._team_id = team_id
        # #234: every app that signs in (App Store app first = primary, then the
        # beta app). Apple binds an authorization code and the refresh token it
        # yields to the client that requested it, so each call names its client.
        self._client_ids = client_ids
        self._key_id = key_id
        self._private_key = private_key
        # Injected in tests (httpx.MockTransport); None → a short-lived client.
        self._client = http_client
        self._token_url = token_url
        self._revoke_url = revoke_url

    def _resolve_client_id(self, client_id: str | None) -> str:
        """The client a call authenticates as; None = primary (pre-#234 rows)."""
        return client_id or self._client_ids[0]

    def _client_secret(self, client_id: str) -> str:
        return generate_client_secret(
            team_id=self._team_id,
            client_id=client_id,
            key_id=self._key_id,
            private_key=self._private_key,
        )

    async def exchange_authorization_code(
        self, code: str, *, client_id: str | None = None
    ) -> AppleTokenExchange:
        """Exchange a single-use ``authorization_code`` for Apple's tokens.

        ``client_id`` is the app the code was issued to (the verified id_token's
        ``aud``); it must be one of the configured clients. Native SIWA needs no
        ``redirect_uri`` (that is for web flows). Raises ``AppleOAuthError`` on
        any failure (the route maps it to 502)."""
        client_id = self._resolve_client_id(client_id)
        if client_id not in self._client_ids:
            raise AppleOAuthError(f"Apple client {client_id!r} is not configured")
        data = {
            "client_id": client_id,
            "client_secret": self._client_secret(client_id),
            "code": code,
            "grant_type": "authorization_code",
        }
        payload = await self._post_form(data)
        # Apple signals failures as {"error": "invalid_grant", ...} (sometimes with
        # a 200), so treat an error key as a failure even past raise_for_status.
        if "error" in payload:
            raise AppleOAuthError(f"Apple token exchange error: {payload['error']}")
        return AppleTokenExchange(refresh_token=payload.get("refresh_token"))

    async def revoke(
        self,
        token: str,
        *,
        token_type_hint: str = "refresh_token",
        client_id: str | None = None,
    ) -> None:
        """Revoke a stored Apple token at ``/auth/revoke`` (61.5, Session C).

        Called when an account is deleted, to sever its Sign in with Apple grant.
        Apple answers an **empty 200** on success — unlike token exchange there is
        no JSON body to parse, so this does not go through ``_post_form``. Raises
        ``AppleOAuthError`` on any non-2xx or network failure; the delete route
        swallows it (best-effort, F4).

        ``client_id`` is the app whose sign-in produced ``token`` (stored next to
        it, #234); Apple rejects a revoke authenticated as a different client.
        None = the primary client, which issued every pre-#234 token."""
        client_id = self._resolve_client_id(client_id)
        data = {
            "client_id": client_id,
            "client_secret": self._client_secret(client_id),
            "token": token,
            "token_type_hint": token_type_hint,
        }
        try:
            await self._post(self._revoke_url, data)
        except httpx.HTTPError as exc:
            raise AppleOAuthError("Apple token revoke failed") from exc

    async def _post_form(self, data: dict) -> dict:
        try:
            resp = await self._post(self._token_url, data)
            return resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise AppleOAuthError("Apple OAuth request failed") from exc

    async def _post(self, url: str, data: dict) -> httpx.Response:
        """POST a form to Apple and return the raised-for-status response.

        Shared by token exchange (parses a JSON body) and revoke (empty body);
        raises the bare ``httpx.HTTPError`` so each caller wraps it with its own
        ``AppleOAuthError`` message."""
        if self._client is not None:
            resp = await self._client.post(url, data=data)
        else:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(url, data=data)
        resp.raise_for_status()
        return resp


def build_apple_oauth_client(settings) -> AppleOAuthClient:
    """Construct an ``AppleOAuthClient`` from app settings (Session B/C)."""
    return AppleOAuthClient(
        team_id=settings.apple_signin_team_id,
        client_id=settings.apple_signin_client_ids,
        key_id=settings.apple_signin_key_id,
        private_key=settings.apple_signin_private_key,
    )
