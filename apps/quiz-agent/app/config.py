"""Runtime configuration for quiz-agent (#36 task 2.20).

Centralises env-var lookups so the voice-quiz read path can resolve
`DATABASE_URL` once, instead of every collaborator re-reading `os.environ`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


def _attest_environment(raw: str) -> str:
    """Map the ``APP_ATTEST_PRODUCTION`` env var to an accepted-environment policy.

    ``both``/``any``/``all`` → accept development *and* production attestations on
    one backend (lets Xcode→device and TestFlight/App Store builds share a backend
    without flipping a flag); truthy → production only; anything else (incl. unset
    / ``false``) → development only.
    """
    value = raw.strip().lower()
    if value in {"both", "any", "all"}:
        return "both"
    if value in {"1", "true", "on", "yes", "production", "prod"}:
        return "production"
    return "development"


@dataclass(frozen=True)
class Settings:
    """Subset of env vars the quiz-agent app reads at startup."""

    database_url: Optional[str]
    db_pool_size: int = 5
    db_echo: bool = False
    # Auth Phase 1 (#60). Secret is a Fly secret (≥64-char CSPRNG); unset in
    # plain dev so the app still boots — auth endpoints raise if it is missing.
    auth_jwt_secret: Optional[str] = None
    auth_jwt_issuer: str = "quiz-agent"
    auth_jwt_audience: str = "quiz-agent-clients"
    access_token_ttl_seconds: int = 900  # 15 min (D-spec)
    # Refresh tokens: sliding per-token window, capped by an absolute family age.
    refresh_token_ttl_days: int = 30
    refresh_family_max_days: int = 60
    # #88: lost-response reuse-grace. A used refresh token replayed within this
    # window, whose immediate successor is still unused, is treated as a dropped
    # rotation response (the cellular-blip-while-driving case) and recovered
    # instead of revoking the family. 0 disables it (strict RFC 9700 detection).
    refresh_retry_grace_seconds: int = 60
    # App Attest (#60 Part B). `app_attest_required` is the prod-on/dev-off gate;
    # `app_attest_app_id` is "<TeamID>.<BundleID>" (the rpId the device attests
    # over). `app_attest_environment` selects which aaguid environment(s) the
    # verifier accepts: "development" (Xcode→device builds), "production"
    # (TestFlight/App Store), or "both" (one backend serves both build
    # distributions without flipping a flag).
    attest_challenge_ttl_seconds: int = 300  # 5 min — one attest/assert round-trip
    app_attest_required: bool = False
    app_attest_app_id: Optional[str] = None
    app_attest_environment: str = "development"
    # Sign in with Apple (#61, auth Phase 2). All optional so the app still boots
    # without them — only the /auth/apple flow (Session B/C) requires them set.
    # `apple_signin_client_id` is the app bundle id (com.missinghue.hangs): for a
    # native SIWA flow it is both the id_token `aud` and the client_secret `sub`.
    # `apple_signin_private_key` is the .p8 contents (a Fly secret); `…_key_id` /
    # `…_team_id` form the client_secret header.kid / issuer. `apple_token_enc_key`
    # is a Fernet key (one `Fernet.generate_key()`) for encrypting Apple's refresh
    # token at rest (F1/F2).
    apple_signin_client_id: Optional[str] = None
    apple_signin_key_id: Optional[str] = None
    apple_signin_team_id: Optional[str] = None
    apple_signin_private_key: Optional[str] = None
    apple_token_enc_key: Optional[str] = None

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            database_url=os.getenv("DATABASE_URL"),
            db_pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
            db_echo=os.getenv("DB_ECHO", "false").lower() == "true",
            auth_jwt_secret=os.getenv("AUTH_JWT_SECRET"),
            auth_jwt_issuer=os.getenv("AUTH_JWT_ISSUER", "quiz-agent"),
            auth_jwt_audience=os.getenv("AUTH_JWT_AUDIENCE", "quiz-agent-clients"),
            access_token_ttl_seconds=int(os.getenv("ACCESS_TOKEN_TTL_SECONDS", "900")),
            refresh_token_ttl_days=int(os.getenv("REFRESH_TOKEN_TTL_DAYS", "30")),
            refresh_family_max_days=int(os.getenv("REFRESH_FAMILY_MAX_DAYS", "60")),
            refresh_retry_grace_seconds=int(
                os.getenv("REFRESH_RETRY_GRACE_SECONDS", "60")
            ),
            attest_challenge_ttl_seconds=int(
                os.getenv("ATTEST_CHALLENGE_TTL_SECONDS", "300")
            ),
            app_attest_required=os.getenv("APP_ATTEST_REQUIRED", "false").lower()
            in {"1", "true", "on", "yes"},
            app_attest_app_id=os.getenv("APP_ATTEST_APP_ID"),
            app_attest_environment=_attest_environment(
                os.getenv("APP_ATTEST_PRODUCTION", "false")
            ),
            apple_signin_client_id=os.getenv("APPLE_SIGNIN_CLIENT_ID"),
            apple_signin_key_id=os.getenv("APPLE_SIGNIN_KEY_ID"),
            apple_signin_team_id=os.getenv("APPLE_SIGNIN_TEAM_ID"),
            apple_signin_private_key=os.getenv("APPLE_SIGNIN_PRIVATE_KEY"),
            apple_token_enc_key=os.getenv("APPLE_TOKEN_ENC_KEY"),
        )


def get_settings() -> Settings:
    return Settings.from_env()
