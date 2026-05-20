"""PackGenerator + Stage Protocol.

`PackGenerator.run` walks an ordered list of `Stage` objects, threading a
shared `OrderContext` through each one. Each stage opens a step via the
`ProgressSink` (`start_step` → `finish_step` + `publish`), so SSE clients
observe the same shape Phase 1's stub produced.

On a stage exception the orchestrator records a `failed` event through the
sink with `error=repr(exc)` (matches the Phase 1 stub's failure shape from
`app.worker.tasks._handle_failure`) and re-raises. Job/order row updates
(`status="failed"`, retry semantics) remain the worker's responsibility —
task 2.10 wires that outer handler.
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
        stages_list = list(stages)
        # F8 source-quality gate (#36 task 2.15): every PackGenerator run
        # must start with a sourcing stage so questions inherit a real
        # `source_url`/`source_excerpt` rather than an LLM hallucination.
        if not stages_list or stages_list[0].name != "sourcing":
            raise ValueError(
                "PackGenerator requires a SourcingStage as the first stage "
                "(first stage name must be 'sourcing'); got "
                f"{[s.name for s in stages_list] or 'empty stage list'}"
            )
        self.stages = stages_list
        self.sink_factory = sink_factory
        # Populated by `run` so the worker (task 2.10) can read
        # `ctx.cost_cents` to update `job.total_cost_cents`.
        self.last_ctx: OrderContext | None = None

    async def run(self, order: GenerationOrder) -> QuestionPack | None:
        """Execute every stage in order; emit progress events; return the pack.

        Stages run sequentially. After each stage `ctx.cost_cents` accumulates
        `StageResult.cost_cents`. If a stage raises, subsequent stages are
        skipped, a `failed` event is emitted with `error=repr(exc)`, and the
        exception propagates.

        The returned `QuestionPack` is produced by `PersistStage` (task 2.9) —
        it sets `ctx.pack_id` and includes the pack in its `StageResult.info`
        under `"pack"`. When the stage list does not include a `PersistStage`
        (e.g. unit tests in task 2.3), `run` returns `None`.
        """
        sink = self.sink_factory(str(order.id))
        ctx = OrderContext(
            order_id=order.id,
            prompt=order.prompt,
            language=order.language,
            target_count=order.target_count,
            category=order.category,
            theme=order.theme,
        )

        self.last_ctx = ctx

        total = max(len(self.stages), 1)
        pack: QuestionPack | None = None

        for index, stage in enumerate(self.stages, start=1):
            event_id = await sink.start_step(stage.name)
            try:
                result = await stage.run(ctx, sink)
            except Exception as exc:
                await sink.start_step("failed", info={"error": repr(exc)})
                raise

            ctx.cost_cents += result.cost_cents
            await sink.finish_step(stage.name, event_id, info=result.info)

            progress = int(index / total * 100)
            await sink.publish(event_id, stage.name, progress, info=result.info)

            stage_pack = result.info.get("pack") if result.info else None
            if isinstance(stage_pack, QuestionPack):
                pack = stage_pack

        return pack
