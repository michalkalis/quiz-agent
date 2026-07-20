"""Rate limiting configuration using slowapi (#65).

In-memory storage, per Fly instance. Used purely as defense-in-depth on the
billable LLM / web-search routes (generation + verification): they are already
admin-key gated, so this only bounds the blast radius if that key leaks —
per-instance granularity is fine for that.

``fly_client_ip`` moved to ``quiz_shared.net.util`` (was copy-pasted verbatim
in both apps, backend arch review 2026-07-18) — re-exported here so existing
imports/tests keep working.
"""

from quiz_shared.net.util import fly_client_ip
from slowapi import Limiter

__all__ = ["fly_client_ip", "limiter"]

limiter = Limiter(key_func=fly_client_ip)
