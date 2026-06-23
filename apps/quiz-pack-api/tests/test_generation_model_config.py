"""Config resolution for the #72 Lever-A generation/critique models (P1.1).

WHY these assertions matter: P1.1 makes the creative-generation and critique
models *config-driven* while keeping them *dormant*. Two promises must hold or
the issue's discipline ("nothing changes output until Phase 6") breaks:

1. With no env set, the generator must build with exactly today's models
   (``gpt-4o`` / ``gpt-4o-mini``, sourced from the factory role constants) —
   output unchanged.
2. An override flag (e.g. ``GENERATION_MODEL=claude-opus-4-8``) must actually
   reach the constructed generator, because Phase 6 flips the flag, not the code.

The OpenRouter slug for any override is asserted in ``test_llm_factory.py``;
here we only prove the call-site wiring picks the right *direct* id.
"""

from __future__ import annotations

import pytest

from app.api.routes import _build_advanced_generator


def test_dormant_default_keeps_todays_models(monkeypatch: pytest.MonkeyPatch) -> None:
    """No flag set → unchanged production models (gpt-4o / gpt-4o-mini)."""
    monkeypatch.delenv("GENERATION_MODEL", raising=False)
    monkeypatch.delenv("CRITIQUE_MODEL", raising=False)

    gen = _build_advanced_generator()

    assert gen.generation_model == "gpt-4o"
    assert gen.critique_model == "gpt-4o-mini"


def test_generation_model_override_reaches_generator(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """GENERATION_MODEL flag overrides only the creative-gen model."""
    monkeypatch.setenv("GENERATION_MODEL", "claude-opus-4-8")
    monkeypatch.delenv("CRITIQUE_MODEL", raising=False)

    gen = _build_advanced_generator()

    assert gen.generation_model == "claude-opus-4-8"
    assert gen.critique_model == "gpt-4o-mini"  # untouched fallback


def test_critique_model_override_reaches_generator(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CRITIQUE_MODEL flag overrides only the critique model."""
    monkeypatch.delenv("GENERATION_MODEL", raising=False)
    monkeypatch.setenv("CRITIQUE_MODEL", "claude-haiku-4-5")

    gen = _build_advanced_generator()

    assert gen.generation_model == "gpt-4o"  # untouched fallback
    assert gen.critique_model == "claude-haiku-4-5"
