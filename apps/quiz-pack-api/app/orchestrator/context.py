"""OrderContext + StageResult — the mutable state threaded through stages."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from quiz_shared.models.question import Question


@dataclass
class OrderContext:
    """Mutable state carried through every Stage.

    Stages read fields they consume (e.g. SourcingStage reads category/theme),
    write fields they produce (e.g. SourcingStage writes `facts`), and
    increment `cost_cents` as they make billable API calls.
    """

    order_id: uuid.UUID
    prompt: str
    language: str
    target_count: int
    category: str | None = None
    theme: str | None = None
    pack_id: uuid.UUID | None = None
    facts: list[Any] = field(default_factory=list)
    questions: list[Question] = field(default_factory=list)
    scores: dict[str, dict[str, float]] = field(default_factory=dict)
    cost_cents: int = 0


@dataclass
class StageResult:
    """Returned by `Stage.run`. `info` is published to the ProgressSink.

    `cost_cents` is added to `OrderContext.cost_cents` by `PackGenerator`.
    """

    info: dict[str, Any] = field(default_factory=dict)
    cost_cents: int = 0
