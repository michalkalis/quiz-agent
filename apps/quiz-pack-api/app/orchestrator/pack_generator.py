"""PackGenerator + Stage Protocol.

Interface-only in task 2.1. The concrete `run()` implementation lands in
task 2.3; this file currently defines the class signature so callers and
test scaffolding can import it.
"""

from __future__ import annotations

from typing import Callable, Protocol, Sequence

from app.db.models import GenerationOrder, QuestionPack
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink


class Stage(Protocol):
    """One step in the pack-generation pipeline.

    Concrete stages (SourcingStage, GenerationStage, VerificationStage,
    ScoringStage, DedupStage, PersistStage) are thin adapters over the
    existing collaborators in `app.{sourcing,generation,verification,scoring}`.
    """

    name: str

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        """Mutate `ctx` in-place, return a StageResult with cost + info."""
        ...


class PackGenerator:
    """Walks a GenerationOrder through an ordered list of Stages."""

    def __init__(
        self,
        stages: Sequence[Stage],
        sink_factory: Callable[[str], ProgressSink],
    ) -> None:
        self.stages = list(stages)
        self.sink_factory = sink_factory

    async def run(self, order: GenerationOrder) -> QuestionPack:
        """Execute every stage in order. Implemented in task 2.3."""
        raise NotImplementedError("PackGenerator.run lands in task 2.3")
