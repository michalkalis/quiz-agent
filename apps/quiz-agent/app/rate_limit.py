"""Rate limiting configuration using slowapi.

In-memory storage suitable for single-instance Fly.io deployment.
"""

from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)
