"""Startup invariants that must hold before the API begins serving traffic.

Each check raises a clear `RuntimeError` on failure. Failures crash the worker
during Fly's health-check grace period so the deploy rolls back cleanly.
"""

from __future__ import annotations

import logging
from typing import Any


def warn_if_insecure_production(
    settings: Any, environment: str | None, logger: logging.Logger
) -> None:
    """Log loudly when prod ships with App Attest effectively disabled (#65).

    App Attest defaults to inert (``app_attest_required=False``), so the whole
    #60 attestation investment ships off unless a Fly secret turns it on. We
    log an error rather than refuse to boot — a hard boot-fail on a misconfig
    could take down prod, whereas a loud ``logger.error`` in the deploy logs
    surfaces it without that risk. Logger is injected so this is unit-testable.

    Only fires in production; development/test boots are silent.
    """
    if environment != "production":
        return
    if not settings.app_attest_required:
        logger.error(
            "SECURITY: App Attest is INERT in production (APP_ATTEST_REQUIRED is "
            "off). Anonymous bootstrap will mint identities without device "
            "attestation. Set APP_ATTEST_REQUIRED=on and APP_ATTEST_APP_ID to "
            "enforce it (#60 Part B)."
        )
    elif not settings.app_attest_app_id:
        logger.error(
            "SECURITY: APP_ATTEST_REQUIRED is on but APP_ATTEST_APP_ID is unset — "
            "attestation cannot be verified. Set APP_ATTEST_APP_ID "
            "('<TeamID>.<BundleID>') to enforce App Attest (#60 Part B)."
        )

    from .auth.identity import legacy_grace_enabled

    if legacy_grace_enabled():
        logger.error(
            "SECURITY: LEGACY_USER_ID_GRACE is ON in production — requests "
            "without a bearer token pass unauthenticated through the auth gate "
            "(each pass is logged as 'AUTH GRACE'). Flip LEGACY_USER_ID_GRACE=off "
            "once all live clients send bearers (#65, founder decision #5)."
        )
