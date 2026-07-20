"""Rate limiting configuration using slowapi.

In-memory storage suitable for single-instance Fly.io deployment.

Backend arch review 2026-07-18: this limiter guards unauthenticated identity
minting (routes/auth.py) — the storage is per-machine, so limits reset per
instance if Fly ever scales this service out to >1 machine (see the "Scaling
constraint" section in README.md, which already documents the same
single-machine ceiling for session state). No action needed today; revisit
alongside that section if/when a second machine is provisioned.

``fly_client_ip`` moved to ``quiz_shared.net.util`` (was copy-pasted verbatim
in both apps) — re-exported here so existing imports/tests keep working.
"""

from quiz_shared.net.util import fly_client_ip
from slowapi import Limiter

__all__ = ["fly_client_ip", "limiter"]


# Key on the real client IP (#65). Was ``get_remote_address`` — on Fly that is
# the proxy, collapsing every ``@limiter.limit`` onto one global bucket. Setting
# it here re-keys all existing decorators; the explicit ``key_func=fly_client_ip``
# at routes/auth.py:52,182 is now redundant but harmless.
limiter = Limiter(key_func=fly_client_ip)
