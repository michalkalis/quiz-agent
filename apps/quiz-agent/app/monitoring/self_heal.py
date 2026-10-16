"""Switch to an alternative route when a provider credit runs out (#207).

Founder 2026-10-16: when a credit is critical and another route exists, the
server switches by itself and says so in the alert mail; where none exists it
only alerts.

What still runs over OpenRouter in quiz-agent: only question embeddings (the
gateway route; most questions already carry a stored embedding). The answer
judge's fallback has gone straight to OpenAI since 207.11, TTS/STT are direct,
translation runs on the Anthropic API. So "off OpenRouter" means: this process
flips ``LLM_GATEWAY`` to ``direct`` and drops the cached embedding clients, as
long as a direct OpenAI key exists. It lasts until the next restart, when the
Fly secret applies again (and the next hourly check switches again if the
balance is still critical).

ElevenLabs and Anthropic need no switch here: a refused ElevenLabs call
already falls back to OpenAI voice/transcription per request, and the Claude
judge falls back to gpt-4o-mini per call (hot_path_llm).
"""

from __future__ import annotations

import logging
import os

from quiz_shared.llm import factory as llm_factory
from quiz_shared.utils import embeddings

logger = logging.getLogger(__name__)


def reroute_off_openrouter() -> str:
    """Move this process's OpenRouter traffic to direct OpenAI if possible;
    returns one sentence for the alert mail saying what happened."""
    if llm_factory.gateway() != llm_factory.OPENROUTER:
        return "Automatic action: none needed, this server is not routing through OpenRouter."
    if not os.getenv("OPENAI_API_KEY"):
        return "Automatic action: none possible, no direct OpenAI key on this server."
    os.environ["LLM_GATEWAY"] = llm_factory.DIRECT
    embeddings.reset_clients()
    logger.warning(
        "Self-heal: LLM_GATEWAY switched openrouter -> direct in this process"
    )
    return (
        "Automatic action: quiz-agent switched its OpenRouter traffic (question "
        "embeddings) to direct OpenAI until its next restart. Top up OpenRouter, "
        "or make it permanent with `fly secrets set LLM_GATEWAY=direct -a quiz-agent-api`."
    )
