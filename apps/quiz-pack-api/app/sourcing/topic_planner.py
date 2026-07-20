"""TopicPlanner — LLM proposer of diverse topics, used to refresh the pool (#72 F-1).

The no-category path samples curated topics from ``TopicPool`` at runtime (no
per-pack LLM call). This planner is the *offline* engine behind that pool: run
occasionally by ``scripts/refresh_topic_pool.py`` to propose fresh candidates
that get merged into ``topic_pool.json``. Keeping the LLM here — off the
generation hot path — preserves unbounded novelty without paying an LLM call (or
risking its failure) on every "surprise me" pack.

A cheap model proposes a spread of *concrete* topics across distinct domains,
explicitly avoiding broad/generic/military clusters (the founder's Phase-6b
complaint). Mirrors ``OpenTriviaFactRewriter``'s contract: lazy ``llm_factory``
client, an ``_available()`` guard, and a fail-safe — any unavailability,
exception, or unparseable output returns ``None`` so a refresh run degrades
cleanly instead of crashing. Routed through the #53 factory; never instantiates
an SDK client directly.
"""

from __future__ import annotations

import json
import os
import re
from typing import Optional

from quiz_shared.llm import factory as llm_factory

# Default spread. Tavily issues roughly 2 searches per topic, so this also caps
# web-search volume (the "reduce web-search volume for future gen" steer): 5
# topics ≈ 10 searches, comparable to today's 4-topic generic fallback but far
# more diverse.
DEFAULT_TOPIC_COUNT = 5

# Hard ceiling on a single proposed topic's length (chars). A model that returns
# a sentence instead of a topic would otherwise become a junk Tavily query.
_MAX_TOPIC_LEN = 60

_PLANNER_PROMPT = """You are planning a general-knowledge quiz that should feel varied, fresh, and surprising.

Propose exactly {count} quiz topics to source interesting facts from.

Rules:
- Each topic is a CONCRETE, specific subject (e.g. "deep-sea bioluminescence", "the history of the printing press", "volcanic islands of Iceland") — NOT a broad domain ("science", "history", "nature") and NOT generic ("general knowledge", "trivia", "random facts").
- Spread the topics across DISTINCT domains — mix across e.g. nature, physical science, history, geography, art & music, sport, food & drink, technology, space, language & culture. Do NOT cluster several topics in one domain. In particular, do NOT skew toward military, war, or weapons topics.
- Choose topics rich in surprising, verifiable facts that make a fun quiz.
- 2 to 6 words each, in English.

Return ONLY a JSON array of {count} topic strings, e.g. ["topic one", "topic two"]. No prose, no keys, no code fences."""


class TopicPlanner:
    """Cheap-model planner that proposes diverse concrete topics, or ``None``."""

    def __init__(
        self,
        model: str = "gpt-4o-mini",
        topic_count: int = DEFAULT_TOPIC_COUNT,
    ) -> None:
        self._model = model
        self._topic_count = topic_count
        self._client = None

    def _available(self) -> bool:
        """Whether the cheap model is reachable (see OpenTriviaFactRewriter)."""
        return (
            bool(os.getenv("OPENAI_API_KEY"))
            or llm_factory.gateway() == llm_factory.OPENROUTER
        )

    async def propose(self) -> Optional[list[str]]:
        """Return a diverse concrete topic list, or ``None`` on any failure.

        Temperature is left at the model default (≈1.0) on purpose: each refresh
        run proposes a *different* spread, so repeatedly refreshing the pool
        grows its variety instead of re-proposing the same handful of topics.
        """
        if not self._available():
            return None
        if self._client is None:
            # Offline generation pipeline — needs longer than the voice-path default.
            self._client = llm_factory.openai_client(
                async_=True, timeout=llm_factory.GENERATION_TIMEOUT
            )
        try:
            response = await self._client.chat.completions.create(
                model=llm_factory.resolve_model(self._model),
                messages=[
                    {
                        "role": "user",
                        "content": _PLANNER_PROMPT.format(count=self._topic_count),
                    }
                ],
            )
            text = response.choices[0].message.content or ""
        except Exception:
            return None
        return self._parse(text)

    def _parse(self, text: str) -> Optional[list[str]]:
        """Parse the model output into a clean topic list, or ``None``.

        Tolerant of code fences and of a ``{"topics": [...]}`` wrapper; rejects
        anything that isn't ultimately a non-empty list of short strings.
        Dedupes case-insensitively, strips, drops over-long entries, caps at
        ``topic_count`` so a chatty model can't inflate Tavily volume.
        """
        raw = _strip_code_fence(text).strip()
        try:
            parsed = json.loads(raw)
        except (ValueError, TypeError):
            return None
        if isinstance(parsed, dict):
            parsed = parsed.get("topics")
        if not isinstance(parsed, list):
            return None

        topics: list[str] = []
        seen: set[str] = set()
        for item in parsed:
            if not isinstance(item, str):
                continue
            topic = item.strip().strip('"').strip()
            if not topic or len(topic) > _MAX_TOPIC_LEN:
                continue
            key = topic.lower()
            if key in seen:
                continue
            seen.add(key)
            topics.append(topic)
            if len(topics) >= self._topic_count:
                break
        return topics or None


def _strip_code_fence(text: str) -> str:
    """Drop a leading/trailing markdown code fence if the model wrapped output."""
    fence = re.match(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", text, re.DOTALL)
    return fence.group(1) if fence else text
