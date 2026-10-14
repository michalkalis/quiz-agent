"""Env pins of the weekly fresh-entertainment run (#202 — weekly fresh entertainment job).

Fly app secrets win over ``fly machine run --env`` (the first dry run on
2026-10-14 still resolved prod's openrouter gateway and bedrock roles), so the
job pins its roles itself: :func:`apply` writes ``ENV_PINS`` into the process
env. It must run before ``quiz_shared.llm.factory`` is imported, because role
ids are read at import time. This module therefore imports nothing from the
pipeline. ``fresh_roles.check_roles`` still verifies the result.
"""

from __future__ import annotations

import os

OPUS = "claude-opus-5-5"
SONNET = "claude-sonnet-5-5"

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
    # #203 203.9: pack sub-themes are a customer-order feature; the weekly job
    # never plans them, whatever the worker's secret says.
    "PACK_SUBTHEMES": "0",
}

# #203 203.9: the house style has its own switch here, so the worker's
# GEN_HOUSE_STYLE secret (same Fly app) never reaches the weekly job. Only an
# explicit FRESH_HOUSE_STYLE=1 turns it on (the #202 blind-round arm).
HOUSE_STYLE_ENV = "FRESH_HOUSE_STYLE"


# Founder 2026-10-14: a manual run may use the Claude Code subscription
# ("spusti ostrý beh, ale cez subscription"); the weekly job stays on the API.
# Local only: on Fly (FLY_APP_NAME set) a session run is refused.
SESSION_ENV = "FRESH_TOPUP_SESSION"


def session_run() -> bool:
    return os.environ.get(SESSION_ENV) == "1"


def apply() -> None:
    """Override whatever the environment (prod secrets) says with the pins."""
    os.environ.update(ENV_PINS)
    os.environ["GEN_HOUSE_STYLE"] = (
        "1" if os.environ.get(HOUSE_STYLE_ENV, "0").strip() == "1" else "0"
    )
    if session_run():
        if os.environ.get("FLY_APP_NAME"):
            raise RuntimeError(
                f"{SESSION_ENV}=1 is for a manual local run; the server job "
                "always runs on the Anthropic API"
            )
        os.environ["LLM_GATEWAY"] = "session"
