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

from arq.constants import default_queue_name as arq_default_queue_name
from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from quiz_shared.auth.identity import JWT_AUDIENCE, JWT_ISSUER

_BUNDLED_APPLE_ROOT = Path(__file__).parent / "storekit" / "certs" / "AppleRootCA-G3.cer"

# #193: how often an ARQ worker refreshes `<queue>:health-check` (TTL = interval + 1 s).
# ARQ's 1 h default is too coarse to tell a dead worker from a live one; at 60 s the
# key's presence IS the heartbeat that GET /api/v1/admin/worker/heartbeat reports to
# the prod monitor (the beta's session worker on mba once lay dead for ~20 h unseen).
WORKER_HEALTH_CHECK_INTERVAL_S = 60


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
    # every purchase until the deploy declares which store environment(s) it
    # serves, mirroring quiz-agent's RC_ALLOWED_ENVIRONMENT. Comma-separated
    # (#193): prod sets "Production,Sandbox" because App Review and TestFlight
    # always buy in Sandbox while real customers buy in Production.
    app_bundle_id: str = "com.missinghue.hangs"
    storekit_environment: Optional[frozenset[str]] = None
    storekit_root_cert_path: Path = _BUNDLED_APPLE_ROOT

    # Queue routing (#172 — session worker: custom packy v bete cez subscription).
    # `order_queue_name` is where the API and the sweep PUT jobs; `worker_queue_name`
    # is what this worker process TAKES them from. Both default to ARQ's own default
    # queue, so an unset deploy behaves exactly as before. Prod flips only
    # ORDER_QUEUE_NAME (jobs land on the session queue the mba worker consumes); the
    # mba worker sets both, plus a single slot and a long budget, because a
    # `claude -p` pack run is far slower than the paid-API one and the subscription
    # quota is shared with interactive work.
    order_queue_name: str = arq_default_queue_name
    worker_queue_name: str = arq_default_queue_name
    worker_max_jobs: int = 2
    worker_job_timeout_s: int = 3600

    # Pause switch for NEW custom-pack orders (#193 task 193.9). Same name as
    # quiz-agent's setting that disables the order entry in the app; this one
    # enforces it server-side, also for builds that don't know the switch.
    # Off refuses only order creation: status, stream, retry and the
    # idempotent replay of an existing (already paid) order keep working.
    pack_orders_enabled: bool = True

    # Sentry (backend arch review 2026-07-18). Per-deploy Fly secret; unset →
    # no Sentry init (dev). Read by main.py AND worker.on_startup (separate
    # processes, both init).
    sentry_dsn: Optional[str] = None

    @field_validator("storekit_environment", mode="before")
    @classmethod
    def _normalize_storekit_environment(cls, value: object) -> Optional[frozenset[str]]:
        """Accept only Apple's two store environments, else fail closed (None).

        Any unrecognized token voids the whole value, so a typo can never
        silently narrow the set to the half that happened to parse.
        """
        if value is None:
            return None
        raw = value.split(",") if isinstance(value, str) else value
        tokens = {str(t).strip().capitalize() for t in raw if str(t).strip()}  # type: ignore[union-attr]
        if not tokens or not tokens <= {"Sandbox", "Production"}:
            return None
        return frozenset(tokens)

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
