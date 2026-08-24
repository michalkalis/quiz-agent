"""Coverage for the #72 generation-quality flags (issue #72 P0.2; defaults
flipped 2026-08).

WHY these assertions matter: model overrides and the still-dormant flags
(``VETO_SHADOW``, ``EXPIRY_CLASSIFICATION``, ``MCQ_CRITIQUE_TELEMETRY``) must
return their "off" value with no env var set, so the pipeline behaves exactly
as it does in production today for those levers. The quality-safeguard flags
(``V3_ESCAPE_HATCH``, ``GEN_CRAFT_GUARDS``, ``VETO_ENFORCE``,
``CRAFT_GUARDS_ENFORCE``) flipped to default ON 2026-08 — prod Fly secrets
already set them, so an unset local/CLI run was silently missing the
safeguards (Bedrock field test 2026-08-01). Those assertions are the guard
against a regression back to "silently dormant"; the explicit-disable cases
prove the rollback lever ("0"/"false"/"no"/"off") still works.
"""

from __future__ import annotations

import pytest

from app import feature_flags

_QUALITY_SAFEGUARDS = (
    feature_flags.v3_escape_hatch,
    feature_flags.gen_craft_guards,
    feature_flags.veto_enforce,
    feature_flags.craft_guards_enforce,
)
_QUALITY_SAFEGUARD_VARS = (
    "V3_ESCAPE_HATCH",
    "GEN_CRAFT_GUARDS",
    "VETO_ENFORCE",
    "CRAFT_GUARDS_ENFORCE",
)


def test_dormant_flags_stay_off_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    """No env set → today's behaviour for the still-dormant levers: model
    overrides absent, VETO_SHADOW/EXPIRY_CLASSIFICATION/MCQ_CRITIQUE_TELEMETRY
    off."""
    for var in (
        "GENERATION_MODEL",
        "CRITIQUE_MODEL",
        "VETO_SHADOW",
        "EXPIRY_CLASSIFICATION",
        "MCQ_CRITIQUE_TELEMETRY",
    ):
        monkeypatch.delenv(var, raising=False)

    assert feature_flags.generation_model() is None
    assert feature_flags.critique_model() is None
    assert feature_flags.veto_shadow() is False
    assert feature_flags.expiry_classification() is False
    assert feature_flags.mcq_critique_telemetry() is False


def test_quality_safeguards_default_on(monkeypatch: pytest.MonkeyPatch) -> None:
    """No env set → the quality-safeguard flags default ON (prod parity)."""
    for var in _QUALITY_SAFEGUARD_VARS:
        monkeypatch.delenv(var, raising=False)

    for flag in _QUALITY_SAFEGUARDS:
        assert flag() is True


@pytest.mark.parametrize("value", ["0", "false", "FALSE", "no", "off", "  Off  "])
def test_quality_safeguards_explicit_falsy_disables(
    monkeypatch: pytest.MonkeyPatch, value: str
) -> None:
    """An explicit falsy value is still the rollback lever for each safeguard."""
    for var in _QUALITY_SAFEGUARD_VARS:
        monkeypatch.setenv(var, value)

    for flag in _QUALITY_SAFEGUARDS:
        assert flag() is False


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
    """VETO_SHADOW stays on the plain `_truthy` (dormant-by-default) parser."""
    monkeypatch.setenv("VETO_SHADOW", value)
    assert feature_flags.veto_shadow() is True


@pytest.mark.parametrize("value", ["0", "false", "no", "off", "", "maybe"])
def test_non_truthy_toggles_stay_off(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    monkeypatch.setenv("VETO_SHADOW", value)
    assert feature_flags.veto_shadow() is False


# --- #166 D21b — pipeline slim-down flags (founder 2026-08-24) ----------------


def test_d21b_slimdown_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    """The approved prod config needs NO env: direct generation with the
    direct v1 prompt, no best-of-N (critique/duels), no LLM judge gate."""
    for var in ("DIRECT_GENERATION", "GEN_PROMPT_VERSION", "BEST_OF_N", "JUDGE_GATE"):
        monkeypatch.delenv(var, raising=False)
    assert feature_flags.direct_generation_default() is True
    assert feature_flags.generation_prompt_version() == "direct_v1"
    assert feature_flags.best_of_n() is False
    assert feature_flags.judge_gate() is False


def test_d21b_slimdown_rollback_levers(monkeypatch: pytest.MonkeyPatch) -> None:
    """Every #166 removal keeps an env rollback (the #135 traceability
    convention): one env var restores the pre-#166 behaviour."""
    monkeypatch.setenv("DIRECT_GENERATION", "0")
    monkeypatch.setenv("GEN_PROMPT_VERSION", "v2_cot")
    monkeypatch.setenv("BEST_OF_N", "1")
    monkeypatch.setenv("JUDGE_GATE", "1")
    assert feature_flags.direct_generation_default() is False
    assert feature_flags.generation_prompt_version() == "v2_cot"
    assert feature_flags.best_of_n() is True
    assert feature_flags.judge_gate() is True
