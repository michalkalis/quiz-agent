"""The pinned role map of the weekly fresh run (#202 task 202.3 / 202.4).

Why: the founder approved questions made by one exact model set (#201 blind
comparison). Prod secrets such as ``LLM_ROLE_CRITIQUE`` or ``VERIFY_MODEL``
would silently swap a role, and an unpriced model would count as $0 against
the $15 cap — both must stop the run before any paid call. The workflow's
``--env`` pins must stay identical to the code's, or the check would fail
every Wednesday (or, worse, pass on a different map).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from app.corpus import fresh_roles
from app.corpus.fresh_roles import ENV_PINS, RoleMapError, check_roles
from app.generation import topicality_classifier
from quiz_shared.llm import factory as llm_factory

WORKFLOW = Path(__file__).resolve().parents[4] / ".github/workflows/fresh-topup.yml"


@pytest.fixture
def pinned(monkeypatch):
    """The environment the workflow gives the machine, applied to the
    import-time role constants too (they are read once at import)."""
    for key, value in ENV_PINS.items():
        monkeypatch.setenv(key, value)
    for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY"):
        monkeypatch.setenv(key, "test-placeholder")
    monkeypatch.setenv("DATABASE_URL", "postgresql://x/y")
    monkeypatch.setattr(llm_factory, "CRITIQUE", fresh_roles.OPUS)
    monkeypatch.setattr(llm_factory, "FACTCHECK", fresh_roles.SONNET)
    monkeypatch.setattr(llm_factory, "DEDUP_JUDGE", fresh_roles.SONNET)
    monkeypatch.setattr(llm_factory, "GEN_ALT_SHARE", 0.0)
    monkeypatch.setattr(topicality_classifier, "_CLASSIFIER_MODEL", fresh_roles.OPUS)
    return monkeypatch


def test_pinned_environment_passes_with_per_language_answerer(pinned):
    resolved = check_roles(["en", "sk", "cs"])
    assert resolved["en"]["answerability"] == "claude-haiku-5-5"
    assert (
        resolved["sk"]["answerability"]
        == resolved["cs"]["shape"]
        == "claude-sonnet-5-5"
    )
    assert resolved["en"]["verify"] == resolved["en"]["critique"] == "claude-opus-5-5"


@pytest.mark.parametrize(
    ("key", "value", "role"),
    [
        ("VERIFY_MODEL", "deepseek-v4-pro", "verify"),
        ("CRITIQUE_MODEL", "gpt-5.6-sol", "critique"),
        ("CASUAL_PLAYER_GATE", "1", "casual_player"),
        ("ANSWERABILITY_CHECK", "0", "answerability"),
        ("LLM_GATEWAY", "openrouter", "gateway"),
    ],
)
def test_a_prod_secret_that_moves_a_role_fails(pinned, key, value, role):
    pinned.setenv(key, value)
    with pytest.raises(RoleMapError, match=rf"\.{role}:"):
        check_roles(["sk"])


def test_prod_factcheck_role_fails(pinned):
    pinned.setattr(llm_factory, "FACTCHECK", "gpt-5-mini")
    with pytest.raises(RoleMapError, match="factcheck"):
        check_roles(["en"])


def test_a_model_without_price_fails(pinned):
    pinned.setattr(fresh_roles.llm_usage, "cost_cents_for", lambda *_a: 0.0)
    with pytest.raises(RoleMapError, match="has no list price"):
        check_roles(["en"])


def test_claude_without_anthropic_key_fails(pinned):
    pinned.setenv("ANTHROPIC_API_KEY", "")
    with pytest.raises(RoleMapError, match="ANTHROPIC_API_KEY|Anthropic API"):
        check_roles(["en"])


def test_workflow_env_pins_equal_the_code_pins():
    pins = dict(re.findall(r"--env (\w+)=(\S+)", WORKFLOW.read_text()))
    assert pins == ENV_PINS
