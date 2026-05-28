"""Runtime configuration for quiz-agent (#36 task 2.20).

Centralises env-var lookups so the voice-quiz read path can resolve
`DATABASE_URL` once, instead of every collaborator re-reading `os.environ`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Settings:
    """Subset of env vars the quiz-agent app reads at startup."""

    database_url: Optional[str]

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(database_url=os.getenv("DATABASE_URL"))


def get_settings() -> Settings:
    return Settings.from_env()
