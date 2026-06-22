"""Rate limiting configuration using slowapi (#65).

In-memory storage, per Fly instance. Used purely as defense-in-depth on the
billable LLM / web-search routes (generation + verification): they are already
admin-key gated, so this only bounds the blast radius if that key leaks —
per-instance granularity is fine for that.
"""

from fastapi import Request
from slowapi import Limiter
from slowapi.util import get_remote_address


def fly_client_ip(request: Request) -> str:
    """Rate-limit key = the real client IP.

    slowapi's default ``get_remote_address`` returns the peer address, which on
    Fly.io is the proxy — so a per-IP limit would be global and useless. Fly puts
    the real client IP in the ``Fly-Client-IP`` header; fall back to the peer
    address off-Fly (local dev / tests have no such header).
    """
    return request.headers.get("Fly-Client-IP") or get_remote_address(request)


limiter = Limiter(key_func=fly_client_ip)
