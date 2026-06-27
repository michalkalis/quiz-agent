"""Tests for the Apple OAuth client (issue #61, task 61.4).

The token exchange is the one place we trade Apple's single-use code for the
refresh token we keep, so the contract pinned here is: the request authenticates
with a real ES256 client_secret and the documented form fields; the refresh token
is captured when present and is ``None`` when absent (Apple does not always send
one); and any failure surfaces as ``AppleOAuthError`` (which the route maps to 502
and Session C's revoke treats as best-effort) rather than a silent success.
"""

from __future__ import annotations

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.auth.apple_oauth import AppleOAuthClient, AppleOAuthError

TEAM_ID = "TEAM123456"
CLIENT_ID = "com.missinghue.hangs"
KEY_ID = "KEY1234567"


def _p8() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


def _client(handler, **overrides) -> AppleOAuthClient:
    return AppleOAuthClient(
        team_id=TEAM_ID,
        client_id=CLIENT_ID,
        key_id=KEY_ID,
        private_key=_p8(),
        http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
        **overrides,
    )


@pytest.mark.asyncio
async def test_exchange_captures_refresh_token_and_sends_a_valid_request():
    """Happy path: the refresh token is returned, and the request carries the
    grant_type, code, client_id, and a client_secret that is a well-formed ES256
    JWT with the right header.kid — i.e. Apple would actually accept it."""
    seen: dict = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen["url"] = str(req.url)
        seen["form"] = dict(httpx.QueryParams(req.content.decode()))
        return httpx.Response(
            200, json={"refresh_token": "apple-rt", "access_token": "a"}
        )

    result = await _client(handler).exchange_authorization_code("the-code")
    assert result.refresh_token == "apple-rt"

    assert seen["url"] == "https://appleid.apple.com/auth/token"
    form = seen["form"]
    assert form["grant_type"] == "authorization_code"
    assert form["code"] == "the-code"
    assert form["client_id"] == CLIENT_ID
    # The client_secret is a real ES256 JWT signed for Apple (header.kid = KEY_ID).
    header = jwt.get_unverified_header(form["client_secret"])
    assert header["alg"] == "ES256" and header["kid"] == KEY_ID


@pytest.mark.asyncio
async def test_exchange_returns_none_when_apple_sends_no_refresh_token():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"access_token": "a", "token_type": "Bearer"})

    result = await _client(handler).exchange_authorization_code("code")
    assert result.refresh_token is None


@pytest.mark.asyncio
async def test_non_2xx_raises_apple_oauth_error():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error": "invalid_grant"})

    with pytest.raises(AppleOAuthError):
        await _client(handler).exchange_authorization_code("expired-code")


@pytest.mark.asyncio
async def test_error_body_with_200_still_raises():
    """Apple sometimes returns an error envelope with a 200 — treat the error key
    as a failure, never as 'no refresh token, success'."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"error": "invalid_client"})

    with pytest.raises(AppleOAuthError):
        await _client(handler).exchange_authorization_code("code")


def test_construction_fails_loud_without_full_key_set():
    with pytest.raises(RuntimeError):
        AppleOAuthClient(
            team_id="", client_id=CLIENT_ID, key_id=KEY_ID, private_key="x"
        )
