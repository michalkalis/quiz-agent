"""Rate limiting configuration using slowapi.

In-memory storage suitable for single-instance Fly.io deployment.
"""

from fastapi import Request
from slowapi import Limiter
from slowapi.util import get_remote_address


def fly_client_ip(request: Request) -> str:
    """Rate-limit key = the real client IP (decision D6).

    slowapi's default ``get_remote_address`` returns the peer address, which on
    Fly.io is the proxy — so a per-IP limit would be global and useless. Fly puts
    the real client IP in the ``Fly-Client-IP`` header; fall back to the peer
    address off-Fly (local dev / tests have no such header).
    """
    return request.headers.get("Fly-Client-IP") or get_remote_address(request)


# Key on the real client IP (#65). Was ``get_remote_address`` — on Fly that is
# the proxy, collapsing every ``@limiter.limit`` onto one global bucket. Setting
# it here re-keys all existing decorators; the explicit ``key_func=fly_client_ip``
# at routes/auth.py:52,182 is now redundant but harmless.
limiter = Limiter(key_func=fly_client_ip)
