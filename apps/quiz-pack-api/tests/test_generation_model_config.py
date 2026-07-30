"""Config resolution for the generation/critique models (#72 P1.1 wiring).

WHY these assertions matter: the generation and critique models are
config-driven (``GENERATION_MODEL`` / ``CRITIQUE_MODEL`` env flags) with the
factory role constants as the fallback. Two promises must hold:

1. With no env set, the generator builds with the factory's frontier role
   defaults (2026-07-30 founder policy: best models, no mini-class in the
   generation pipeline) — asserted against the constants, not literals, so a
   deliberate factory bump never breaks this wiring test.
2. An override flag must actually reach the constructed generator — the Fly
   env, not the code, selects the deployed model (e.g. a future
   ``bedrock:...`` id once AWS credentials are configured).
"""

from __future__ import annotations

import pytest

from quiz_shared.llm import factory as llm_factory

from app.api.routes import _build_advanced_generator


def test_default_uses_factory_frontier_roles(monkeypatch: pytest.MonkeyPatch) -> None:
    """No flag set → the factory's frontier role defaults, verbatim."""
    monkeypatch.delenv("GENERATION_MODEL", raising=False)
    monkeypatch.delenv("CRITIQUE_MODEL", raising=False)

    gen = _build_advanced_generator()

    assert gen.generation_model == llm_factory.GEN
    assert gen.critique_model == llm_factory.CRITIQUE


def test_generation_model_override_reaches_generator(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """GENERATION_MODEL flag overrides only the creative-gen model."""
    monkeypatch.setenv("GENERATION_MODEL", "claude-opus-5")
    monkeypatch.delenv("CRITIQUE_MODEL", raising=False)

    gen = _build_advanced_generator()

    assert gen.generation_model == "claude-opus-5"
    assert gen.critique_model == llm_factory.CRITIQUE  # untouched fallback


def test_critique_model_override_reaches_generator(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CRITIQUE_MODEL flag overrides only the critique model."""
    monkeypatch.delenv("GENERATION_MODEL", raising=False)
    monkeypatch.setenv("CRITIQUE_MODEL", "claude-haiku-4-5")

    gen = _build_advanced_generator()

    assert gen.generation_model == llm_factory.GEN  # untouched fallback
    assert gen.critique_model == "claude-haiku-4-5"
