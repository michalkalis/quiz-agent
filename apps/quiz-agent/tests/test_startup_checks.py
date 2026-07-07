"""Tests for startup_checks: warn_if_insecure_production.

(`verify_chroma_path_on_volume` was retired with the ChromaDB decommission,
#41 D7 — pgvector has no on-volume path to verify.)
"""

from __future__ import annotations

import logging
from types import SimpleNamespace


from app.startup_checks import warn_if_insecure_production


# ── warn_if_insecure_production (#65) ────────────────────────────────────────


def _settings(required: bool, app_id: str | None = None) -> SimpleNamespace:
    return SimpleNamespace(app_attest_required=required, app_attest_app_id=app_id)


def _security_errors(records: list[logging.LogRecord]) -> list[str]:
    return [
        r.getMessage()
        for r in records
        if r.levelno == logging.ERROR and "SECURITY" in r.getMessage()
    ]


def test_warn_prod_app_attest_inert_logs_error(caplog) -> None:
    """Prod with App Attest off → a loud SECURITY error (does not raise)."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(_settings(required=False), "production", logger)
    errors = _security_errors(caplog.records)
    assert errors and "INERT" in errors[0]


def test_warn_development_is_silent(caplog) -> None:
    """Non-prod boots never warn, even with App Attest off."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(_settings(required=False), "development", logger)
    assert _security_errors(caplog.records) == []


def test_warn_prod_required_but_no_app_id_logs_error(caplog) -> None:
    """Required-on but APP_ATTEST_APP_ID unset → the second loud error path."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id=None), "production", logger
        )
    errors = _security_errors(caplog.records)
    assert errors and "APP_ATTEST_APP_ID" in errors[0]


def test_warn_prod_fully_configured_is_silent(caplog, monkeypatch) -> None:
    """Required-on with an app id and grace off → no warning."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="TEAMID.com.missinghue.hangs"),
            "production",
            logger,
        )
    assert _security_errors(caplog.records) == []


def test_warn_prod_grace_on_logs_error(caplog, monkeypatch) -> None:
    """Grace on in production → loud SECURITY error, even when App Attest is
    fully configured (#65 follow-up, founder decision #5 2026-07-05)."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="TEAMID.com.missinghue.hangs"),
            "production",
            logger,
        )
    errors = _security_errors(caplog.records)
    assert errors and "LEGACY_USER_ID_GRACE" in errors[0]


def test_warn_development_grace_is_silent(caplog, monkeypatch) -> None:
    """Grace on outside production stays silent — it is the intended dev default."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="x"), "development", logger
        )
    assert _security_errors(caplog.records) == []
