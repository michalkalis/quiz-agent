"""Guard tests for the question-management admin gate (#91 item 3).

``app.api.admin.verify_admin_key`` protects question import/management. The
misc-route twin already has HTTP-level pins (test_admin_premium.py); this pins
the second site the same way so neither can quietly regress to an open route
or a non-constant-time compare that mishandles the unconfigured case.
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from app.api.admin import verify_admin_key

_ADMIN_KEY = "super-secret-admin-key"


def test_correct_key_passes(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", _ADMIN_KEY)
    verify_admin_key(x_admin_key=_ADMIN_KEY)  # no exception


def test_wrong_key_rejected_401(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", _ADMIN_KEY)
    with pytest.raises(HTTPException) as exc:
        verify_admin_key(x_admin_key="wrong")
    assert exc.value.status_code == 401


def test_non_ascii_key_rejected_401_not_typeerror(monkeypatch):
    """compare_digest raises TypeError on non-ASCII str — a client header is
    latin-1-decoded, so without the bytes-compare an attacker gets a 500."""
    monkeypatch.setenv("ADMIN_API_KEY", _ADMIN_KEY)
    with pytest.raises(HTTPException) as exc:
        verify_admin_key(x_admin_key="wröng-\xff")
    assert exc.value.status_code == 401


def test_unconfigured_server_rejects_500(monkeypatch):
    """No ADMIN_API_KEY on the server must never mean an open door."""
    monkeypatch.delenv("ADMIN_API_KEY", raising=False)
    with pytest.raises(HTTPException) as exc:
        verify_admin_key(x_admin_key="anything")
    assert exc.value.status_code == 500
