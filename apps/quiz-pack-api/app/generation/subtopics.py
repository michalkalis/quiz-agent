"""Approved per-category subtopic taxonomy for #170 (task 170.3, D4).

``subtopics.json`` next to this module is the founder-approved coverage map
(locked decision 5: the model proposed, the founder signed off — gate F1,
2026-09-04 round 1 + 2026-09-07 round 2). Schema ``{language: {category:
[subtopic, …]}}``, keyed exactly like a coverage cell (D1). The runtime only
reads it — no LLM call, no mutation. Regenerate proposals with
``scripts/propose_subtopics.py``; never edit this file at runtime.

Fail-loud: asking for a language/category that is not in the file raises
``KeyError`` — the coverage map must never steer by a taxonomy that does
not exist (A1).
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

SUBTOPICS_PATH = Path(__file__).with_name("subtopics.json")


@lru_cache(maxsize=1)
def load_subtopics() -> dict[str, dict[str, tuple[str, ...]]]:
    """The whole approved taxonomy, immutable and cached for the process."""
    with SUBTOPICS_PATH.open(encoding="utf-8") as fh:
        raw = json.load(fh)
    return {
        language: {category: tuple(subtopics) for category, subtopics in by_cat.items()}
        for language, by_cat in raw.items()
    }


def subtopics_for(category: str, language: str = "en") -> tuple[str, ...]:
    """Approved subtopics of one category; ``KeyError`` when unknown."""
    taxonomy = load_subtopics()
    if language not in taxonomy:
        raise KeyError(
            f"no subtopics for language {language!r} in {SUBTOPICS_PATH.name}"
        )
    if category not in taxonomy[language]:
        raise KeyError(
            f"no subtopics for category {category!r} ({language}) in "
            f"{SUBTOPICS_PATH.name}; known: {sorted(taxonomy[language])}"
        )
    return taxonomy[language][category]
