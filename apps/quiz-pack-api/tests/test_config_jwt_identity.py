"""quiz-pack-api's JWT issuer/audience defaults must match the shared contract.

quiz-agent signs access tokens; quiz-pack-api verify-only mirrors them for
`GET /v1/orders?mine=1` (#95). Both configs used to hardcode the same
literals independently — nothing enforced they matched, so editing one
app's default would silently break cross-service verification. This test
pins quiz-pack-api's effective default to `quiz_shared.auth.identity`, the
one place both apps now read from.
"""

from __future__ import annotations

from quiz_shared.auth.identity import JWT_AUDIENCE, JWT_ISSUER

from app.config import Settings


def test_default_jwt_issuer_and_audience_match_shared_contract(monkeypatch):
    monkeypatch.delenv("AUTH_JWT_ISSUER", raising=False)
    monkeypatch.delenv("AUTH_JWT_AUDIENCE", raising=False)
    settings = Settings()
    assert settings.auth_jwt_issuer == JWT_ISSUER
    assert settings.auth_jwt_audience == JWT_AUDIENCE
