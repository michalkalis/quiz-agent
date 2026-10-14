"""The pinned role map of the weekly fresh run (#202 task 202.3 / 202.4).

Why: the founder approved questions made by one exact model set (#201 blind
comparison). Prod secrets such as ``LLM_ROLE_CRITIQUE`` or ``VERIFY_MODEL``
would silently swap a role, and an unpriced model would count as $0 against
the $15 cap — both must stop the run before any paid call. The workflow's
``--env`` pins must stay identical to the code's, or the check would fail
every Wednesday (or, worse, pass on a different map).
"""

from __future__ import annotations

import os
import subprocess
import sys
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


def test_pins_beat_prod_secrets_and_the_workflow_runs_the_pinning_entry_point():
    """Fly app secrets win over `machine run --env`: the first dry run still
    resolved prod's openrouter gateway and bedrock roles. The pins must be
    applied in-process before the factory reads its role ids at import time,
    and the workflow must start that entry point, not the job module."""
    probe = (
        "from app.corpus import fresh_pins; fresh_pins.apply();"
        "from quiz_shared.llm import factory as f;"
        "print(f.gateway(), f.CRITIQUE, f.GEN, f.FACTCHECK)"
    )
    prod_like = {
        **os.environ,
        "LLM_GATEWAY": "openrouter",
        "LLM_ROLE_CRITIQUE": "bedrock:deepseek.v3.2",
        "LLM_ROLE_GEN": "bedrock:zai.glm-5",
        "LLM_ROLE_FACTCHECK": "gpt-5-mini",
    }
    out = subprocess.run(
        [sys.executable, "-c", probe],
        env=prod_like,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    assert out == [
        "direct",
        ENV_PINS["LLM_ROLE_CRITIQUE"],
        ENV_PINS["LLM_ROLE_GEN"],
        ENV_PINS["LLM_ROLE_FACTCHECK"],
    ]
    workflow = WORKFLOW.read_text()
    assert "python -m app.corpus.run_fresh_topup" in workflow
    assert "--env " not in workflow


def test_seed_steps_are_pinned_and_priced(pinned):
    """Founder 2026-10-14: Haiku 5.5 gathers, Opus 5.5 picks. The check must
    see the models the seed calls REALLY use and a list price for each."""
    for lang in ("en", "sk", "cs"):
        roles = check_roles([lang])[lang]
        assert roles["seed_gather"] == "claude-haiku-5-5"
        assert roles["seed_pick"] == "claude-opus-5-5"
    for model in ("claude-haiku-5-5", "claude-opus-5-5"):
        assert fresh_roles.llm_usage.cost_cents_for(model, 1_000_000, 0) > 0


@pytest.mark.parametrize(
    ("module", "attr", "role", "moved_to"),
    [
        ("seed_gather", "GATHER_MODEL", "seed_gather", "claude-opus-5-5"),
        ("seed_research", "PICK_MODEL", "seed_pick", "claude-haiku-5-5"),
    ],
)
def test_a_moved_seed_model_fails_the_role_check(pinned, module, attr, role, moved_to):
    """Opus doing the searching multiplied the seed spend (up to $3.2 per
    language); Haiku picking returned 3 candidates for en. Either swap must stop
    the run before the first paid call."""
    import importlib

    pinned.setattr(importlib.import_module(f"app.corpus.{module}"), attr, moved_to)
    with pytest.raises(RoleMapError, match=rf"\.{role}: resolved '{moved_to}'"):
        check_roles(["en"])


def test_session_run_is_local_only_and_switches_the_gateway():
    """Founder 2026-10-14: a manual run may use the subscription, the weekly
    server job never: the switch flips the gateway locally and refuses on Fly."""
    base = {**os.environ, "LLM_GATEWAY": "openrouter", "FRESH_TOPUP_SESSION": "1"}
    base.pop("FLY_APP_NAME", None)
    probe = (
        "from app.corpus import fresh_pins; fresh_pins.apply();"
        "from quiz_shared.llm import factory as f; print(f.gateway())"
    )
    out = subprocess.run(
        [sys.executable, "-c", probe],
        env=base,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    assert out == ["session"]
    on_fly = subprocess.run(
        [sys.executable, "-c", probe],
        env={**base, "FLY_APP_NAME": "quiz-pack-api"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert on_fly.returncode != 0 and "manual local run" in on_fly.stderr
