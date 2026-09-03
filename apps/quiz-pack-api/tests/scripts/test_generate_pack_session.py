"""#169 — session gateway behaviour of the generate_pack CLI."""

from __future__ import annotations

import scripts.generate_pack as generate_pack


class TestJudgesUnderSessionGateway:
    def test_session_gateway_forces_judges_off(self, monkeypatch):
        """Founder 2026-09-02: D21 showed the judge panel adds no signal, and on
        the subscription it burned ~80 % of the quota — session runs must never
        pay for it, even without --no-judges."""
        monkeypatch.setenv("LLM_GATEWAY", "session")
        assert generate_pack._judges_enabled(no_judges=False) is False

    def test_api_runs_keep_the_explicit_lever(self, monkeypatch):
        """The paid API path is the source of truth: its judges default stays
        ON and --no-judges remains the only way to drop them."""
        monkeypatch.delenv("LLM_GATEWAY", raising=False)
        assert generate_pack._judges_enabled(no_judges=False) is True
        assert generate_pack._judges_enabled(no_judges=True) is False
