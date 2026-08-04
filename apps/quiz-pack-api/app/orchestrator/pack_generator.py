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

import asyncio
import logging
import os
from pathlib import Path
from typing import Callable, Protocol, Sequence

import sentry_sdk

from app.db.models import GenerationOrder, QuestionPack
from app.generation.pattern_routing import MCQ_EMPHASIS_MARKER
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink

logger = logging.getLogger(__name__)

# #139 — belt over the per-call client timeouts: no single stage may run
# longer than this before failing loud. Must stay under WorkerSettings.
# job_timeout (3600s), or ARQ's cancel fires first and this belt never
# triggers. 1200s is sized for the real worst case measured 2026-08-04: a
# legit pack_30 generating stage on frontier models runs many sequential
# LLM calls (batch + critique + MCQ), and the hang case is already bounded
# by the 300s per-call timeout — this only catches pathological loops.
# Env-driven like the gen-layer flags (see app.feature_flags docstring) —
# the orchestrator keeps zero dependency on app.config.
_STAGE_TIMEOUT_SECONDS = float(os.getenv("STAGE_TIMEOUT_SECONDS", "1200"))


def _rss_mb() -> float | None:
    """Current process RSS in MB (Linux /proc; None where unavailable).

    #139 acceptance 4: the worker runs on a 512MB Fly machine and OOM is a
    candidate trigger for the silent-hang failure mode — per-stage RSS in the
    step log + breadcrumbs is how we get the number from a real prod run.
    """
    try:
        statm = Path("/proc/self/statm").read_text().split()
        return int(statm[1]) * os.sysconf("SC_PAGE_SIZE") / (1024 * 1024)
    except (OSError, ValueError, IndexError):
        return None


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
        # #139 — the stage currently (or last) executing, so the worker's
        # cancellation handler can name where the job died even though a
        # cancelled coroutine raises no stage exception of its own.
        self.current_stage: str | None = None

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
            # Deterministic marker check, not LLM-side gating — #42 task
            # 42.20 blocker (root cause D): `ctx.prompt` never reaches the
            # generation LLM, so MCQ emphasis must travel as an explicit
            # bool that GenerationStage hands to the generator.
            mcq_emphasis=MCQ_EMPHASIS_MARKER in (order.prompt or ""),
        )

        self.last_ctx = ctx

        total = max(len(self.stages), 1)
        pack: QuestionPack | None = None

        for index, stage in enumerate(self.stages, start=1):
            self.current_stage = stage.name
            rss = _rss_mb()
            sentry_sdk.add_breadcrumb(
                category="pipeline",
                message=f"stage {stage.name} start",
                data={"order_id": str(order.id), "rss_mb": rss},
            )
            logger.info(
                "stage start order_id=%s stage=%s rss_mb=%s",
                order.id, stage.name, f"{rss:.0f}" if rss is not None else "n/a",
            )
            event_id = await sink.start_step(stage.name)
            try:
                # #139 — the belt over per-call client timeouts: a hang inside
                # a stage becomes a caught TimeoutError here instead of an
                # uncancellable ARQ job_timeout kill with zero diagnostics.
                # (wait_for relies on cancellation, so a cancel-immune hang —
                # e.g. a stuck sync bridge thread — still needs the per-call
                # timeouts; this catches the cancel-responsive ones.)
                result = await asyncio.wait_for(
                    stage.run(ctx, sink), timeout=_STAGE_TIMEOUT_SECONDS
                )
            except TimeoutError:
                timeout_exc = TimeoutError(
                    f"stage {stage.name!r} exceeded "
                    f"STAGE_TIMEOUT_SECONDS={_STAGE_TIMEOUT_SECONDS:.0f}s"
                )
                await sink.start_step("failed", info={"error": repr(timeout_exc)})
                raise timeout_exc from None
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
