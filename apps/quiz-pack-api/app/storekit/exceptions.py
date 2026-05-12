"""StoreKit JWS verification exceptions (issue #33 Task 1.8)."""

from __future__ import annotations


class JWSError(Exception):
    """Base class for all JWS verification failures."""


class JWSInvalid(JWSError):
    """JWS structure/signature/chain is malformed or untrusted.

    Raised for: bad format, alg != ES256, bad cert chain, signature mismatch,
    payload missing required fields, environment mismatch (configuration drift).
    """


class JWSExpired(JWSError):
    """JWS payload has an `expiresDate` in the past.

    Phase 1 is non-consumable-only so this is currently unreachable in prod —
    kept for forward compat with Phase 4 subscription flow.
    """


class JWSWrongBundle(JWSError):
    """JWS `bundleId` does not match the configured `APP_BUNDLE_ID`.

    Treat as a security signal: the JWS was signed for a different app.
    """
