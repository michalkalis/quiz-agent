"""Shared request-IP helper (promoted from both apps' ``app/rate_limit.py``).

``fly_client_ip`` was copy-pasted verbatim in quiz-agent and quiz-pack-api.
Promoted here following the ``quiz_shared.database.engine`` precedent: shared
implementation, thin per-app re-export. Behavior is unchanged.
"""

from __future__ import annotations

from fastapi import Request
from slowapi.util import get_remote_address


def fly_client_ip(request: Request) -> str:
    """Rate-limit key = the real client IP.

    slowapi's default ``get_remote_address`` returns the peer address, which on
    Fly.io is the proxy — so a per-IP limit would be global and useless. Fly puts
    the real client IP in the ``Fly-Client-IP`` header; fall back to the peer
    address off-Fly (local dev / tests have no such header).
    """
    return request.headers.get("Fly-Client-IP") or get_remote_address(request)
