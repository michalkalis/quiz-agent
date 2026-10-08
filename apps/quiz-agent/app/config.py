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

import logging
import re
from typing import Optional

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from quiz_shared.auth.identity import JWT_AUDIENCE, JWT_ISSUER

logger = logging.getLogger(__name__)

_VERSION_RE = re.compile(r"\d+(\.\d+){0,2}")


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


def _rc_environment(raw: Optional[str]) -> Optional[frozenset[str]]:
    """Normalize ``RC_ALLOWED_ENVIRONMENT`` to a set of ``PRODUCTION``/``SANDBOX``.

    Comma-separated so one deployment can serve both stores at once
    (``PRODUCTION,SANDBOX`` — prod must honor TestFlight / App Review purchases,
    which Apple always runs in the sandbox). Unset, empty, or *any* unrecognized
    token → ``None``, and the RC ingest **fails closed** (#101): no webhook/sync
    processing and no entitlement is honored until the deploy declares which
    store environment(s) it serves.
    """
    if raw is None:
        return None
    tokens = {t.strip().upper() for t in raw.split(",") if t.strip()}
    if not tokens or not tokens <= {"PRODUCTION", "SANDBOX"}:
        return None
    return frozenset(tokens)


def _min_app_version(raw: Optional[str]) -> Optional[str]:
    """Normalize a ``MIN_APP_VERSION_*`` value; empty or malformed → ``None``.

    Fails open on purpose: the client blocks play below this version, so a
    typo must disable the gate, not lock every installed build out.
    """
    if raw is None or not raw.strip():
        return None
    value = raw.strip()
    if not _VERSION_RE.fullmatch(value):
        logger.error("Ignoring malformed minimum app version %r", value)
        return None
    return value


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
    # #101 prod/sandbox separation: which RevenueCat purchase environment(s)
    # this deployment ingests + honors — comma-separated, e.g.
    # "PRODUCTION,SANDBOX" on prod (TestFlight + App Review buy in sandbox).
    # None (unset/invalid) = fail closed — RC ingest refuses to process.
    rc_allowed_environment: Optional[frozenset[str]] = None
    # TTS backend selection (founder call 2026-07-26: ElevenLabs/George becomes
    # the quiz voice, OpenAI TTS stays wired up as the backup rather than being
    # deleted). `tts_fallback_provider` set to "none"/empty disables failover.
    # `tts_voice` overrides the provider's default voice — an ElevenLabs voice
    # id or an OpenAI voice name, so it only makes sense alongside a pinned
    # `tts_provider`. `tts_cache_dir` must point at the Fly volume (/data/…)
    # for the audio cache to survive a deploy.
    tts_provider: str = "elevenlabs"
    tts_fallback_provider: Optional[str] = "openai"
    tts_voice: Optional[str] = None
    tts_cache_dir: str = "./data/tts_cache"
    elevenlabs_tts_model: str = "eleven_multilingual_v2"
    openai_tts_model: str = "tts-1"
    # Answer transcription (#184 — batch STT for car noise). Scribe v2 batch is
    # primary: it publishes Slovak quality, takes `keyterms` biasing and returns
    # per-word logprob so trailing noise words can be cut. `stt_fallback_model`
    # is the OpenAI model used when Scribe is unavailable — set it back to
    # "whisper-1" to roll all the way back, or `stt_provider="openai"` to skip
    # Scribe entirely. `stt_trailing_logprob_cutoff`: words below this at the end
    # of a transcript count as noise (logprob ≤ 0, higher = confident).
    # `stt_trim_trailing_low_confidence` (#185 E): whether that noise run is
    # actually cut from the text. OFF until the cutoff is measured on car
    # recordings — an answer in a foreign language ("curling" in a Slovak quiz)
    # scores low confidence and was at risk of being cut; while off, the run is
    # only logged ("would have trimmed …") so it can be calibrated.
    stt_provider: str = "elevenlabs"
    stt_fallback_model: str = "gpt-transcribe"
    elevenlabs_stt_model: str = "scribe_v2"
    stt_trailing_logprob_cutoff: float = -1.0
    stt_trim_trailing_low_confidence: bool = False
    # Provider credit balances (#193 — beta hardening). The daily background
    # check is opt-in (on in fly.toml) so tests and local dev make no outbound
    # calls; the admin endpoint works regardless. Thresholds: OpenRouter in USD
    # left, ElevenLabs in percent of the character quota left.
    provider_balance_check_enabled: bool = False
    provider_balance_initial_delay_s: float = 120.0
    openrouter_low_usd: float = 10.0
    openrouter_critical_usd: float = 3.0
    elevenlabs_low_pct: float = 25.0
    elevenlabs_critical_pct: float = 10.0
    # Remote app switches (#193 task 193.9), served by `GET /api/v1/app-config`
    # so they change with a Fly secret/env update, no code deploy. Defaults
    # are permissive: no minimum version, orders on, no notice. A minimum is a
    # dotted numeric marketing version ("1.2" / "1.2.3"); a malformed value is
    # dropped (logged) rather than served, so a typo never locks every build out.
    min_app_version_app_store: Optional[str] = None
    min_app_version_testflight: Optional[str] = None
    pack_orders_enabled: bool = True
    app_notice_sk: Optional[str] = None
    app_notice_cs: Optional[str] = None
    app_notice_en: Optional[str] = None
    apple_signin_client_id: Optional[str] = None
    apple_signin_key_id: Optional[str] = None
    apple_signin_team_id: Optional[str] = None
    apple_signin_private_key: Optional[str] = None
    apple_token_enc_key: Optional[str] = None

    @field_validator("app_attest_environment", mode="before")
    @classmethod
    def _normalize_attest_environment(cls, value: object) -> str:
        return _attest_environment(str(value))

    @field_validator(
        "min_app_version_app_store", "min_app_version_testflight", mode="before"
    )
    @classmethod
    def _normalize_min_app_version(cls, value: object) -> Optional[str]:
        return _min_app_version(None if value is None else str(value))

    @field_validator("app_notice_sk", "app_notice_cs", "app_notice_en", mode="before")
    @classmethod
    def _normalize_app_notice(cls, value: object) -> Optional[str]:
        text_value = None if value is None else str(value).strip()
        return text_value or None

    @field_validator("rc_allowed_environment", mode="before")
    @classmethod
    def _normalize_rc_environment(cls, value: object) -> Optional[frozenset[str]]:
        return _rc_environment(None if value is None else str(value))


def get_settings() -> Settings:
    return Settings()
