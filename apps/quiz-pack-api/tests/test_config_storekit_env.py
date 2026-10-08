"""STOREKIT_ENVIRONMENT must be explicit per deploy — never an implicit default.

Backend arch review 2026-07-18: `storekit_environment` used to default to
"Sandbox", so a prod deploy missing the Fly secret silently rejected real
Production purchases. The setting is now Optional with a normalizing
validator: unset or invalid → None, and the JWS verifier fails closed
(mirrors quiz-agent's RC_ALLOWED_ENVIRONMENT). `_env_file=None` keeps these
tests hermetic against a host .env.

#193: the value is a comma-separated SET, because prod must accept real
customers (Production) and App Review / TestFlight (always Sandbox) at once.
"""

from __future__ import annotations

import pytest

from app.config import Settings


def test_unset_storekit_environment_is_none(monkeypatch):
    """No secret set → None, so the verifier refuses instead of guessing."""
    monkeypatch.delenv("STOREKIT_ENVIRONMENT", raising=False)
    settings = Settings(_env_file=None)
    assert settings.storekit_environment is None


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("Sandbox", {"Sandbox"}),
        ("sandbox", {"Sandbox"}),
        ("SANDBOX", {"Sandbox"}),
        ("Production", {"Production"}),
        ("production", {"Production"}),
        (" Production ", {"Production"}),
        ("Production,Sandbox", {"Production", "Sandbox"}),
        (" sandbox , PRODUCTION ", {"Production", "Sandbox"}),
    ],
)
def test_valid_values_normalize_to_apple_spelling(raw, expected):
    """Casing/whitespace drift in the Fly secret must not break verification —
    the JWS `environment` claim is compared verbatim against these values."""
    settings = Settings(_env_file=None, storekit_environment=raw)
    assert settings.storekit_environment == frozenset(expected)


def test_comma_separated_secret_parses_from_real_env(monkeypatch):
    """The Fly secret arrives as a plain env string, not JSON. A frozenset field
    must still parse "Production,Sandbox" from the environment — otherwise prod
    would crash at boot (or fail closed) the moment the secret is widened."""
    monkeypatch.setenv("STOREKIT_ENVIRONMENT", "Production,Sandbox")
    settings = Settings(_env_file=None)
    assert settings.storekit_environment == frozenset({"Production", "Sandbox"})


@pytest.mark.parametrize("raw", ["Prod", "staging", "", "true", "Production,Prod", ","])
def test_invalid_values_fail_closed_to_none(raw):
    """A typo'd secret must not half-configure the verifier: any token outside
    Apple's two environments voids the whole value → verification refused,
    rather than silently keeping only the half that parsed."""
    settings = Settings(_env_file=None, storekit_environment=raw)
    assert settings.storekit_environment is None
