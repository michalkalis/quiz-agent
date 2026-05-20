"""SourcingStage — thin wrapper around FactSourcer (issue #36 task 2.4).

The stage maps `OrderContext` → existing `FactSourcer.gather_facts` arguments
and merges the result back into `ctx.facts`. No prompt/behaviour changes,
no extra LLM calls. The wrapper exists so `PackGenerator.run` can compose
sourcing alongside the other Phase 2 stages through a uniform interface.

Cost tracking is coarse on purpose: per the Phase 1 stub seam, Wikipedia
and OpenTriviaDB are free, only Tavily web search is metered. We count one
Tavily call per `gather_facts` invocation that actually used the web-search
source — finer granularity is a Phase 3 concern (#37 cost-cap mid-flight).
"""

from __future__ import annotations

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.sourcing.fact_sourcer import FactSourcer

TAVILY_CENTS_PER_CALL = 1


class SourcingStage:
    """Calls FactSourcer.gather_facts; stores facts on ctx."""

    name = "sourcing"

    def __init__(self, fact_sourcer: FactSourcer) -> None:
        self._fact_sourcer = fact_sourcer

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        topics: list[str] | None = None
        if ctx.category or ctx.theme:
            topics = [t for t in (ctx.category, ctx.theme) if t]

        batch = await self._fact_sourcer.gather_facts(
            count=ctx.target_count * 2,
            topics=topics,
        )
        ctx.facts = list(batch.facts)

        tavily_calls = 1 if "web_search" in batch.sources_used else 0
        cost_cents = tavily_calls * TAVILY_CENTS_PER_CALL

        return StageResult(
            info={
                "facts": len(ctx.facts),
                "sources_used": list(batch.sources_used),
            },
            cost_cents=cost_cents,
        )
