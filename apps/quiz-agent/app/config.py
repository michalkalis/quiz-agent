"""Runtime configuration for quiz-agent (#36 task 2.20).

Centralises env-var lookups so the voice-quiz read path can resolve
`DATABASE_URL` once, instead of every collaborator re-reading `os.environ`.

Declared via pydantic-settings — the same config idiom as quiz-pack-api's
`app/config.py` (backend arch review 2026-07-18: the two apps previously used
contradictory idioms, hand-rolled dataclass here vs BaseSettings there).
`.env` loading stays in `app/main.py` (`load_dotenv` at import), so this class
reads process env only; `get_settings()` stays uncached because callers (RC
ingest, tests) rely on a fresh env read per call.
"""

from __future__ import annotations

from typing import Optional

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from quiz_shared.auth.identity import JWT_AUDIENCE, JWT_ISSUER


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


def _rc_environment(raw: Optional[str]) -> Optional[str]:
    """Normalize ``RC_ALLOWED_ENVIRONMENT`` to ``PRODUCTION``/``SANDBOX``.

    Unset or unrecognized → ``None``, and the RC ingest **fails closed** (#101):
    no webhook/sync processing and no entitlement is honored until the deploy
    declares which store environment it serves.
    """
    if raw is None:
        return None
    value = raw.strip().upper()
    return value if value in {"PRODUCTION", "SANDBOX"} else None


class Settings(BaseSettings):
    """Subset of env vars the quiz-agent app reads at startup."""

    model_config = SettingsConfigDict(extra="ignore", case_sensitive=False)

    database_url: Optional[str] = None
    db_pool_size: int = 5
    db_echo: bool = False
    # Auth Phase 1 (#60). Secret is a Fly secret (≥64-char CSPRNG); unset in
    # plain dev so the app still boots — auth endpoints raise if it is missing.
    auth_jwt_secret: Optional[str] = None
    auth_jwt_issuer: str = JWT_ISSUER
    auth_jwt_audience: str = JWT_AUDIENCE
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
    # distributions without flipping a flag). It is set via the
    # `APP_ATTEST_PRODUCTION` env var (see `_attest_environment`).
    attest_challenge_ttl_seconds: int = 300  # 5 min — one attest/assert round-trip
    app_attest_required: bool = False
    app_attest_app_id: Optional[str] = None
    app_attest_environment: str = Field(
        default="development", validation_alias="APP_ATTEST_PRODUCTION"
    )
    # Sign in with Apple (#61, auth Phase 2). All optional so the app still boots
    # without them — only the /auth/apple flow (Session B/C) requires them set.
    # `apple_signin_client_id` is the app bundle id (com.missinghue.hangs): for a
    # native SIWA flow it is both the id_token `aud` and the client_secret `sub`.
    # `apple_signin_private_key` is the .p8 contents (a Fly secret); `…_key_id` /
    # `…_team_id` form the client_secret header.kid / issuer. `apple_token_enc_key`
    # is a Fernet key (one `Fernet.generate_key()`) for encrypting Apple's refresh
    # token at rest (F1/F2).
    # #101 prod/sandbox separation: which RevenueCat purchase environment this
    # deployment ingests + honors ("PRODUCTION" on prod, "SANDBOX" on staging).
    # None (unset/invalid) = fail closed — RC ingest refuses to process.
    rc_allowed_environment: Optional[str] = None
    apple_signin_client_id: Optional[str] = None
    apple_signin_key_id: Optional[str] = None
    apple_signin_team_id: Optional[str] = None
    apple_signin_private_key: Optional[str] = None
    apple_token_enc_key: Optional[str] = None

    @field_validator("app_attest_environment", mode="before")
    @classmethod
    def _normalize_attest_environment(cls, value: object) -> str:
        return _attest_environment(str(value))

    @field_validator("rc_allowed_environment", mode="before")
    @classmethod
    def _normalize_rc_environment(cls, value: object) -> Optional[str]:
        return _rc_environment(None if value is None else str(value))


def get_settings() -> Settings:
    return Settings()
