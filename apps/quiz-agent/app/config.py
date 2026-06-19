"""Runtime configuration for quiz-agent (#36 task 2.20).

Centralises env-var lookups so the voice-quiz read path can resolve
`DATABASE_URL` once, instead of every collaborator re-reading `os.environ`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


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
    # App Attest (#60 Part B). `app_attest_required` is the prod-on/dev-off gate;
    # `app_attest_app_id` is "<TeamID>.<BundleID>" (the rpId the device attests
    # over) and `app_attest_production` selects the expected aaguid environment.
    attest_challenge_ttl_seconds: int = 300  # 5 min — one attest/assert round-trip
    app_attest_required: bool = False
    app_attest_app_id: Optional[str] = None
    app_attest_production: bool = False

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
            attest_challenge_ttl_seconds=int(
                os.getenv("ATTEST_CHALLENGE_TTL_SECONDS", "300")
            ),
            app_attest_required=os.getenv("APP_ATTEST_REQUIRED", "false").lower()
            in {"1", "true", "on", "yes"},
            app_attest_app_id=os.getenv("APP_ATTEST_APP_ID"),
            app_attest_production=os.getenv("APP_ATTEST_PRODUCTION", "false").lower()
            in {"1", "true", "on", "yes"},
        )


def get_settings() -> Settings:
    return Settings.from_env()
