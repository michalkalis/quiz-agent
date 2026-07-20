"""Settings for quiz-pack-api (issue #33 Task 1.3).

DATABASE_URL handling note: the Fly secret is `postgres://...` (libpq form) so
`psql $DATABASE_URL` keeps working from a remote shell, but SQLAlchemy + asyncpg
needs `postgresql+asyncpg://...`. `app.db.engine.normalize_async_url` rewrites
the scheme at engine-build time; settings keep the raw value the user provided.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Optional

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from quiz_shared.auth.identity import JWT_AUDIENCE, JWT_ISSUER

_BUNDLED_APPLE_ROOT = Path(__file__).parent / "storekit" / "certs" / "AppleRootCA-G3.cer"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    database_url: str = "postgresql+asyncpg://quiz:quiz@localhost:5432/quiz_pack"
    test_database_url: Optional[str] = None
    redis_url: str = "redis://localhost:6379/0"
    db_pool_size: int = 5
    db_echo: bool = False

    # Admin auth (#65). Guards /web admin UI + /api/v1 generation/verify/review
    # routes. Unset → those routers fail closed with 503. Set the Fly secret
    # ADMIN_API_KEY in prod; set a dev value locally to use the admin UI.
    admin_api_key: Optional[str] = None

    # StoreKit (issue #33 Task 1.8). app_bundle_id matches iOS xcconfig
    # BUNDLE_ID_BASE. STOREKIT_ENVIRONMENT is a per-deploy Fly secret, never
    # in code: None (unset or invalid) fails closed — the JWS verifier refuses
    # every purchase until the deploy declares which store environment it
    # serves, mirroring quiz-agent's RC_ALLOWED_ENVIRONMENT. Deploy plan: prod
    # gets an explicit Sandbox secret before this ships (founder keeps
    # TestFlight/sandbox purchases on prod for now); flipping prod to
    # Production is a GA launch step.
    app_bundle_id: str = "com.missinghue.hangs"
    storekit_environment: Optional[str] = None
    storekit_root_cert_path: Path = _BUNDLED_APPLE_ROOT

    # Sentry (backend arch review 2026-07-18). Per-deploy Fly secret; unset →
    # no Sentry init (dev). Read by main.py AND worker.on_startup (separate
    # processes, both init).
    sentry_dsn: Optional[str] = None

    @field_validator("storekit_environment", mode="before")
    @classmethod
    def _normalize_storekit_environment(cls, value: object) -> Optional[str]:
        """Accept only Apple's two store environments, else fail closed (None)."""
        if value is None:
            return None
        normalized = str(value).strip().capitalize()
        return normalized if normalized in {"Sandbox", "Production"} else None

    # Bearer identity (#95). Verify-only mirror of quiz-agent's JWT config —
    # AUTH_JWT_SECRET must be set to the SAME value as the quiz-agent Fly
    # secret or `GET /v1/orders` (mine) rejects every token. Unset → bearer
    # routes fail closed with 503.
    auth_jwt_secret: Optional[str] = None
    auth_jwt_issuer: str = JWT_ISSUER
    auth_jwt_audience: str = JWT_AUDIENCE


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
