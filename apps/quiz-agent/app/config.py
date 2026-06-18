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
        )


def get_settings() -> Settings:
    return Settings.from_env()
