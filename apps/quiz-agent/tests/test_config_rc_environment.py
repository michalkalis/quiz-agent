"""``RC_ALLOWED_ENVIRONMENT`` is a comma-separated allowlist (prod = PRODUCTION,SANDBOX).

Apple runs every TestFlight and App Review purchase in the sandbox store, so a
production backend that honors PRODUCTION alone silently drops every tester's
purchase (the 2026-07-12 failure). The setting therefore accepts several
environments at once — but stays fail-closed: unset, empty, or any unknown
token disables RC ingest entirely rather than guessing.
"""

from __future__ import annotations

import pytest

from app.config import Settings


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("PRODUCTION", frozenset({"PRODUCTION"})),
        ("sandbox", frozenset({"SANDBOX"})),
        ("PRODUCTION,SANDBOX", frozenset({"PRODUCTION", "SANDBOX"})),
        (" sandbox , production ", frozenset({"PRODUCTION", "SANDBOX"})),
    ],
)
def test_allowlist_parses_one_or_many(monkeypatch, raw, expected):
    monkeypatch.setenv("RC_ALLOWED_ENVIRONMENT", raw)
    assert Settings().rc_allowed_environment == expected


@pytest.mark.parametrize("raw", ["", ",", "PRODUCTION,STAGING", "prod"])
def test_allowlist_fails_closed_on_any_unknown_token(monkeypatch, raw):
    """One typo must not quietly shrink the allowlist to the valid remainder —
    the whole setting is rejected so the deploy is visibly misconfigured."""
    monkeypatch.setenv("RC_ALLOWED_ENVIRONMENT", raw)
    assert Settings().rc_allowed_environment is None


def test_unset_fails_closed(monkeypatch):
    monkeypatch.delenv("RC_ALLOWED_ENVIRONMENT", raising=False)
    assert Settings().rc_allowed_environment is None
