"""Access-token sign/verify — re-export of the shared implementation.

The `TokenService` implementation moved to ``quiz_shared.auth.tokens`` (issue
#95 Session 1) so quiz-pack-api can verify the same identity. quiz-agent keeps
this module as the import surface (`app.auth.tokens`) plus the settings-bound
factory; all existing imports keep working unchanged.
"""

from __future__ import annotations

from quiz_shared.auth.tokens import TokenError, TokenService

__all__ = ["TokenError", "TokenService", "build_token_service"]


def build_token_service(settings) -> TokenService:
    """Construct a ``TokenService`` from app settings (``app.config.Settings``)."""
    return TokenService(
        secret=settings.auth_jwt_secret,
        issuer=settings.auth_jwt_issuer,
        audience=settings.auth_jwt_audience,
        access_ttl_seconds=settings.access_token_ttl_seconds,
    )
