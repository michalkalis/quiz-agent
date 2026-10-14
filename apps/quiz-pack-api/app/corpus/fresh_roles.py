"""The pinned model map of the weekly fresh-entertainment run (#202 task 202.3).

The job must run on exactly the roles the founder rated in the #201 blind
comparison (``gettable-entertainment-2026-10-13/B-*.usage.json``). Prod
secrets (``LLM_ROLE_*``, ``VERIFY_MODEL``, ``JUDGE_MODELS``, ``LLM_GATEWAY``)
would otherwise change them silently, so the workflow overrides them with
``ENV_PINS`` and :func:`check_roles` re-reads what the pipeline will REALLY
resolve and refuses to start on any difference — before the first paid call.

Every model in the map must also have a list price (no silent $0 in the spend
cap) and every Claude id must route to the direct Anthropic API (the Max
credit), which needs ``ANTHROPIC_API_KEY``.
"""

from __future__ import annotations

import os

from quiz_shared.llm import anthropic_route
from quiz_shared.llm import factory as llm_factory

from app import feature_flags, llm_usage

OPUS = "claude-opus-5-5"
SONNET = "claude-sonnet-5-5"
HAIKU = "claude-haiku-5-5"
EMBEDDING = "text-embedding-3-small"
OFF = "off"

# The blind answerer: haiku for en, sonnet for the small sk/cs markets
# (recipe § Run; #195). Passed in code to build_stages, so env cannot move it.
ANSWERABILITY_PIN = {"en": HAIKU, "sk": SONNET, "cs": SONNET}

# What the workflow sets on the one-off machine (`--env`), overriding prod.
ENV_PINS: dict[str, str] = {
    "LLM_GATEWAY": "direct",
    "LLM_ROLE_GEN": OPUS,
    "GENERATION_MODEL": OPUS,
    "GEN_ALT_SHARE": "0",
    "LLM_ROLE_CRITIQUE": OPUS,
    "CRITIQUE_MODEL": OPUS,
    "LLM_ROLE_FACTCHECK": SONNET,
    "LLM_ROLE_DEDUP_JUDGE": SONNET,
    "VERIFY_MODEL": OPUS,
    "ANSWERABILITY_CHECK": "1",
    "TOPICALITY_CLASSIFICATION": "1",
    "EXPIRY_CLASSIFICATION": "0",
    "CASUAL_PLAYER_GATE": "off",
    "JUDGE_GATE": "0",
}


class RoleMapError(RuntimeError):
    """A resolved role, price or key differs from the pinned map."""


def expected_roles(lang: str) -> dict[str, str]:
    return {
        "gateway": "direct",
        "generation": OPUS,
        "gen_alt_share": "0",
        "critique": OPUS,
        "topicality": OPUS,
        "expiry": OFF,
        "factcheck": SONNET,
        "answerability": ANSWERABILITY_PIN[lang],
        "shape": ANSWERABILITY_PIN[lang],
        "dedup_judge": SONNET,
        "verify": OPUS,
        "judges": OFF,
        "casual_player": OFF,
        "seeds": OPUS,
    }


def resolve_roles(lang: str) -> dict[str, str]:
    """What the pipeline built by ``fresh_topup`` will actually use for ``lang``.

    Mirrors the reads in ``offline_stages.build_stages`` and the collaborators
    it constructs; the generation, answerability and shape models are passed as
    explicit pins there, judges are off by construction (``judges=False``).
    """
    from app.corpus.seed_research import SEED_MODEL
    from app.generation import topicality_classifier

    critique = feature_flags.critique_model() or llm_factory.CRITIQUE
    return {
        "gateway": llm_factory.gateway(),
        "generation": OPUS,
        "gen_alt_share": f"{llm_factory.GEN_ALT_SHARE:g}",
        "critique": critique,
        "topicality": (
            topicality_classifier._CLASSIFIER_MODEL
            if feature_flags.topicality_classification()
            else OFF
        ),
        "expiry": llm_factory.EXPIRY if feature_flags.expiry_classification() else OFF,
        "factcheck": llm_factory.FACTCHECK,
        "answerability": (
            ANSWERABILITY_PIN[lang] if feature_flags.answerability_check() else OFF
        ),
        "shape": ANSWERABILITY_PIN[lang],
        "dedup_judge": llm_factory.DEDUP_JUDGE,
        "verify": feature_flags.verify_model() or llm_factory.VERIFY,
        "judges": OFF,
        "casual_player": feature_flags.casual_player_gate(),
        "seeds": SEED_MODEL,
    }


def _is_model(value: str) -> bool:
    return value not in (OFF, "direct") and not value.replace(".", "").isdigit()


def check_roles(languages: list[str]) -> dict[str, dict[str, str]]:
    """Raise :class:`RoleMapError` on any mismatch; return the resolved maps."""
    problems: list[str] = []
    resolved: dict[str, dict[str, str]] = {}
    for lang in languages:
        got, want = resolve_roles(lang), expected_roles(lang)
        resolved[lang] = got
        for role, value in want.items():
            if got[role] != value:
                problems.append(
                    f"{lang}.{role}: resolved {got[role]!r}, pinned {value!r}"
                )
    models = {v for roles in resolved.values() for v in roles.values() if _is_model(v)}
    models.add(EMBEDDING)
    for model in sorted(models):
        if llm_usage.cost_cents_for(model, 1_000_000, 0) <= 0:
            problems.append(f"model {model!r} has no list price")
        if anthropic_route.is_claude_model(
            model
        ) and not anthropic_route.routes_to_anthropic(model):
            problems.append(f"model {model!r} would not go to the Anthropic API")
    for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "DATABASE_URL"):
        if not (os.getenv(key) or "").strip():
            problems.append(f"{key} is not set")
    if problems:
        raise RoleMapError("role map check failed: " + "; ".join(problems))
    return resolved
