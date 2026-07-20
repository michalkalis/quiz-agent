"""Cross-service JWT identity contract (issuer/audience) — single source of truth.

quiz-agent signs access tokens with these claims (``auth/tokens.py`` ->
``quiz_shared.auth.tokens.TokenService``); quiz-pack-api verify-only mirrors
them to validate the same tokens on ``GET /v1/orders?mine=1``. Both apps used
to hardcode these literals independently in their own config — nothing
enforced they matched, so editing one app's default would silently break
cross-service verification. This module is now the one place either app's
default reads from.
"""

from __future__ import annotations

JWT_ISSUER = "quiz-agent"
JWT_AUDIENCE = "quiz-agent-clients"
