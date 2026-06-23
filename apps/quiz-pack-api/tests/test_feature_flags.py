"""Coverage for the #72 dormant generation-quality flags (issue #72 P0.2).

WHY these assertions matter: the whole point of Phase 0 is that every new
behaviour ships **dormant** — with no env var set, each flag must return its
"off" value so the pipeline behaves exactly as it does in production today.
If a default ever regressed to "on", P0.2's promise ("output unchanged with
flags off") would silently break, so the default-off cases below are the real
guard. The flip cases prove the accessors actually read the env (Phases 1–4
depend on that) and that truthy parsing is forgiving of common spellings.
"""

from __future__ import annotations

import pytest

from app import feature_flags


def test_flags_are_dormant_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    """No env set → today's behaviour: model overrides absent, toggles off."""
    for var in ("GENERATION_MODEL", "CRITIQUE_MODEL", "V3_ESCAPE_HATCH", "VETO_SHADOW"):
        monkeypatch.delenv(var, raising=False)

    assert feature_flags.generation_model() is None
    assert feature_flags.critique_model() is None
    assert feature_flags.v3_escape_hatch() is False
    assert feature_flags.veto_shadow() is False


def test_model_overrides_read_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GENERATION_MODEL", "claude-opus-4-8")
    monkeypatch.setenv("CRITIQUE_MODEL", "claude-haiku-4-5")

    assert feature_flags.generation_model() == "claude-opus-4-8"
    assert feature_flags.critique_model() == "claude-haiku-4-5"


def test_empty_model_override_is_dormant(monkeypatch: pytest.MonkeyPatch) -> None:
    """An empty string must fall back to None, not force an empty model id."""
    monkeypatch.setenv("GENERATION_MODEL", "")
    assert feature_flags.generation_model() is None


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "on", "  On  "])
def test_truthy_toggles_enable(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    monkeypatch.setenv("V3_ESCAPE_HATCH", value)
    monkeypatch.setenv("VETO_SHADOW", value)
    assert feature_flags.v3_escape_hatch() is True
    assert feature_flags.veto_shadow() is True


@pytest.mark.parametrize("value", ["0", "false", "no", "off", "", "maybe"])
def test_non_truthy_toggles_stay_off(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    monkeypatch.setenv("V3_ESCAPE_HATCH", value)
    assert feature_flags.v3_escape_hatch() is False
