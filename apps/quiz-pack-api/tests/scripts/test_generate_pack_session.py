"""#169 — session gateway behaviour of the generate_pack CLI."""

from __future__ import annotations

import pytest
import scripts.generate_pack as generate_pack
import scripts.replay_dedup_json as replay_dedup_json
from app.orchestrator.stages.grayzone_judge import GrayZoneJudge
from quiz_shared.llm import factory as llm_factory


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


class TestGrayZoneJudgeUnderSessionGateway:
    """#170 D7: the dedup gray-zone judge is a pairwise same-fact verdict, not
    a quality judge — it must NOT hang off the judge-panel cut above. Mirror
    of the #169 quality-panel test: under the session gateway the panel is
    forced OFF while the dedup judge follows its own flag."""

    def test_flag_survives_session_mode_independently_of_the_panel(self, monkeypatch):
        monkeypatch.setenv("LLM_GATEWAY", "session")
        monkeypatch.setenv("DEDUP_GRAYZONE_JUDGE", "1")
        monkeypatch.setenv("GRAYZONE_JUDGE_MAX_CALLS", "7")
        assert generate_pack._judges_enabled(no_judges=False) is False
        judge = replay_dedup_json.build_grayzone_judge()
        assert isinstance(judge, GrayZoneJudge)
        assert judge.max_calls == 7
        assert judge.model == llm_factory.DEDUP_JUDGE

    def test_default_off_in_every_mode(self, monkeypatch):
        monkeypatch.delenv("DEDUP_GRAYZONE_JUDGE", raising=False)
        for gateway in ("session", "direct"):
            monkeypatch.setenv("LLM_GATEWAY", gateway)
            assert replay_dedup_json.build_grayzone_judge() is None

    def test_bad_budget_value_fails_loud(self, monkeypatch):
        monkeypatch.setenv("DEDUP_GRAYZONE_JUDGE", "1")
        monkeypatch.setenv("GRAYZONE_JUDGE_MAX_CALLS", "twenty")
        with pytest.raises(ValueError, match="GRAYZONE_JUDGE_MAX_CALLS"):
            replay_dedup_json.build_grayzone_judge()
