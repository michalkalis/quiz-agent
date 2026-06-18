"""Tests for the access-token service (issue #60, task 60.2).

These assert the *security intent*, not just round-tripping: the subject must
survive sign→verify so identity is server-trusted; tampering, expiry, and
issuer/audience mismatch must each be rejected so a forged or stale token can
never stand in for a valid subject; and the algorithm allowlist must reject the
``alg=none`` confusion attack (the whole reason D3 mandates an explicit list).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import jwt
import pytest

from app.auth.tokens import TokenError, TokenService

SECRET = "x" * 64  # minimum acceptable length per D3
ISSUER = "quiz-agent"
AUDIENCE = "quiz-agent-clients"


def _service(ttl: int = 900) -> TokenService:
    return TokenService(
        secret=SECRET, issuer=ISSUER, audience=AUDIENCE, access_ttl_seconds=ttl
    )


def test_mint_then_verify_recovers_subject():
    """The subject the server signed is the subject it reads back — this is the
    property that makes identity trusted instead of client-asserted."""
    svc = _service()
    token = svc.create_access_token("anon_abc")
    claims = svc.decode_access_token(token)
    assert claims["sub"] == "anon_abc"
    assert claims["iss"] == ISSUER
    assert claims["aud"] == AUDIENCE
    assert "jti" in claims and claims["jti"]


def test_each_token_has_a_unique_jti():
    """jti must be per-token so tokens are individually identifiable
    (future revocation/audit)."""
    svc = _service()
    a = svc.decode_access_token(svc.create_access_token("anon_abc"))
    b = svc.decode_access_token(svc.create_access_token("anon_abc"))
    assert a["jti"] != b["jti"]


def test_expired_token_is_rejected():
    """A token past exp must not verify — otherwise a stale token grants
    indefinite access."""
    svc = _service()
    past = datetime.now(timezone.utc) - timedelta(hours=2)
    token = svc.create_access_token("anon_abc", now=past)
    with pytest.raises(TokenError):
        svc.decode_access_token(token)


def test_tampered_signature_is_rejected():
    """Flipping a payload byte invalidates the HMAC — a client cannot rewrite
    its own subject."""
    svc = _service()
    token = svc.create_access_token("anon_abc")
    header, payload, sig = token.split(".")
    forged = ".".join(
        [header, payload, sig[:-2] + ("aa" if sig[-2:] != "aa" else "bb")]
    )
    with pytest.raises(TokenError):
        svc.decode_access_token(forged)


def test_wrong_audience_is_rejected():
    """A token minted for a different audience must not be accepted here."""
    other = TokenService(
        secret=SECRET, issuer=ISSUER, audience="someone-else", access_ttl_seconds=900
    )
    token = other.create_access_token("anon_abc")
    with pytest.raises(TokenError):
        _service().decode_access_token(token)


def test_wrong_issuer_is_rejected():
    """A token from a different issuer must not be accepted here."""
    other = TokenService(
        secret=SECRET, issuer="evil", audience=AUDIENCE, access_ttl_seconds=900
    )
    token = other.create_access_token("anon_abc")
    with pytest.raises(TokenError):
        _service().decode_access_token(token)


def test_alg_none_token_is_rejected():
    """An attacker-crafted unsigned (alg=none) token must be rejected — this is
    the algorithm-confusion attack the explicit allowlist exists to stop."""
    svc = _service()
    forged = jwt.encode(
        {
            "iss": ISSUER,
            "sub": "anon_attacker",
            "aud": AUDIENCE,
            "iat": datetime.now(timezone.utc),
            "exp": datetime.now(timezone.utc) + timedelta(hours=1),
            "jti": "deadbeef",
        },
        key="",
        algorithm="none",
    )
    with pytest.raises(TokenError):
        svc.decode_access_token(forged)


def test_token_signed_with_other_secret_is_rejected():
    """A different signing key must not verify — secret compromise is the only
    way to forge, not key confusion."""
    other = TokenService(
        secret="y" * 64, issuer=ISSUER, audience=AUDIENCE, access_ttl_seconds=900
    )
    token = other.create_access_token("anon_abc")
    with pytest.raises(TokenError):
        _service().decode_access_token(token)


def test_missing_secret_fails_loud():
    """No secret → construction fails immediately, never silently signs with an
    empty key."""
    with pytest.raises(RuntimeError):
        TokenService(
            secret=None, issuer=ISSUER, audience=AUDIENCE, access_ttl_seconds=900
        )


def test_short_secret_is_rejected():
    """A weak (<64-char) secret is refused at construction (D3)."""
    with pytest.raises(ValueError):
        TokenService(
            secret="too-short", issuer=ISSUER, audience=AUDIENCE, access_ttl_seconds=900
        )
