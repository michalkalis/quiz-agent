"""``fly_client_ip`` must key rate limits on the real client IP, not the Fly proxy (#65).

Before #65 both apps used ``get_remote_address``, which on Fly.io returns the
proxy address — collapsing every per-IP limit into one global bucket (one
abuser could exhaust everyone's quota, and distinct clients shared a counter).

Consolidated from the near-identical apps/quiz-agent/tests/test_rate_limit_key.py
and apps/quiz-pack-api/tests/api/test_generation_rate_limit.py after
``fly_client_ip`` was promoted into ``quiz_shared.net.util`` (backend arch
review 2026-07-18) — both apps' behavior is the same function now, so one
test suite covers the key function itself. Each app keeps its own
limiter-integration tests (bucket behavior, decorator wiring).
"""

from __future__ import annotations

from types import SimpleNamespace

from quiz_shared.net.util import fly_client_ip


class _Req:
    """Minimal Request stand-in: ``.headers`` and ``.client`` (read by get_remote_address)."""

    def __init__(self, fly_ip: str | None = None, peer: str | None = None) -> None:
        self.headers = {} if fly_ip is None else {"Fly-Client-IP": fly_ip}
        self.client = SimpleNamespace(host=peer) if peer else None


def test_fly_client_ip_prefers_header() -> None:
    """On Fly the key is the real client IP from Fly-Client-IP, not the peer."""
    assert fly_client_ip(_Req(fly_ip="9.9.9.9", peer="10.0.0.1")) == "9.9.9.9"


def test_fly_client_ip_falls_back_to_peer_off_fly() -> None:
    """Off Fly (no header — local dev / tests) it falls back to the peer addr."""
    assert fly_client_ip(_Req(fly_ip=None, peer="10.0.0.1")) == "10.0.0.1"
