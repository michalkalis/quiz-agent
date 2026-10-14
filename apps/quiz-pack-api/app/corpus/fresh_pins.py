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
}


# Founder 2026-10-14: a manual run may use the Claude Code subscription
# ("spusti ostrý beh, ale cez subscription"); the weekly job stays on the API.
# Local only: on Fly (FLY_APP_NAME set) a session run is refused.
SESSION_ENV = "FRESH_TOPUP_SESSION"


def session_run() -> bool:
    return os.environ.get(SESSION_ENV) == "1"


def apply() -> None:
    """Override whatever the environment (prod secrets) says with the pins."""
    os.environ.update(ENV_PINS)
    if session_run():
        if os.environ.get("FLY_APP_NAME"):
            raise RuntimeError(
                f"{SESSION_ENV}=1 is for a manual local run; the server job "
                "always runs on the Anthropic API"
            )
        os.environ["LLM_GATEWAY"] = "session"
