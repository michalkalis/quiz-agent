"""TopicPool — curated concrete topics for the no-category path (#72 F-1).

When an order carries no usable topic signal (no category/theme, a generic-only
prompt like "general knowledge"), SourcingStage draws a random spread of concrete
topics from this hand-curated pool instead of letting the literal "general"/
"knowledge" tokens reach Tavily — the listicle/military-bias dead end the
Phase-6b complaint was about. The actual cure for that bias is the stopword set
in ``SourcingStage`` (those words never become a search query); the pool only
answers the follow-on question — *what do we source on when there is no topic?* —
with a fun, cross-domain spread instead of today's four broad buckets.

No per-pack LLM call: the pool is curated data (``topic_pool.json``), sampled
deterministically and for free. The diversity / no-military-skew guarantee is a
property of the curated list, not a prompt instruction a model may ignore. The
list is refreshed *offline* and occasionally by ``scripts/refresh_topic_pool.py``
(which uses ``TopicPlanner`` to propose fresh candidates), keeping novelty
available without putting an LLM step back on the generation path.
"""

from __future__ import annotations

import json
import random
from pathlib import Path
from typing import Optional

# Same default spread as before: 5 topics ≈ 10 Tavily searches (2 per topic),
# comparable to the old four-bucket fallback but concrete and varied.
DEFAULT_TOPIC_COUNT = 5

# Curated data lives next to this module. Scope A (CLI/batch) runs from source,
# so a path-relative load is correct; if Scope B ever wires the pool into the
# installed worker, the JSON must be added to the wheel artifacts then.
POOL_PATH = Path(__file__).with_name("topic_pool.json")


class TopicPool:
    """Samples a diverse concrete topic set from the curated pool, or ``None``.

    Mirrors the old ``TopicPlanner`` caller contract so SourcingStage's wiring is
    a drop-in swap: ``sample()`` returns a topic list or ``None`` (empty/missing
    pool) so the stage keeps its broad-feed fallback rather than crashing.
    """

    def __init__(
        self,
        topic_count: int = DEFAULT_TOPIC_COUNT,
        path: Path = POOL_PATH,
    ) -> None:
        self._topic_count = topic_count
        self._path = path
        self._topics: Optional[list[str]] = None

    def load(self) -> list[str]:
        """Read and cache the curated topics. A missing/garbled file → ``[]``."""
        if self._topics is None:
            try:
                data = json.loads(self._path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                self._topics = []
            else:
                raw = data.get("topics", []) if isinstance(data, dict) else []
                self._topics = [t.strip() for t in raw if isinstance(t, str) and t.strip()]
        return self._topics

    def sample(self, count: Optional[int] = None) -> Optional[list[str]]:
        """Return ``count`` distinct topics drawn at random, or ``None``.

        Random (not fixed) so repeated "surprise me" packs draw a different
        spread; ``random.sample`` guarantees no duplicate topic in one pack.
        """
        n = count or self._topic_count
        pool = self.load()
        if not pool:
            return None
        return random.sample(pool, min(n, len(pool)))


def merge_topics(existing: list[str], proposed: list[str]) -> tuple[list[str], list[str]]:
    """Append the genuinely-new ``proposed`` topics to ``existing`` (pure).

    Case-insensitive dedupe against what's already in the pool *and* within the
    proposed batch, so a refresh never adds "Coral Reefs" next to "coral reefs".
    Returns ``(merged, added)`` — ``added`` lets the refresh tool report (and a
    test assert) exactly what a run changed. Insertion order is preserved and new
    topics land at the end, so the JSON diff reads as a clean append.
    """
    seen = {t.lower() for t in existing}
    merged = list(existing)
    added: list[str] = []
    for topic in proposed:
        key = topic.strip().lower()
        if not key or key in seen:
            continue
        seen.add(key)
        merged.append(topic.strip())
        added.append(topic.strip())
    return merged, added
