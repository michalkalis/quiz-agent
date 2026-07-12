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

from pydantic_settings import BaseSettings, SettingsConfigDict

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
    # BUNDLE_ID_BASE; storekit_environment is "Sandbox" on staging Fly app and
    # "Production" on prod — keep per-deploy via Fly secrets, not in code.
    app_bundle_id: str = "com.missinghue.hangs"
    storekit_environment: str = "Sandbox"
    storekit_root_cert_path: Path = _BUNDLED_APPLE_ROOT

    # Bearer identity (#95). Verify-only mirror of quiz-agent's JWT config —
    # AUTH_JWT_SECRET must be set to the SAME value as the quiz-agent Fly
    # secret or `GET /v1/orders` (mine) rejects every token. Unset → bearer
    # routes fail closed with 503.
    auth_jwt_secret: Optional[str] = None
    auth_jwt_issuer: str = "quiz-agent"
    auth_jwt_audience: str = "quiz-agent-clients"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
