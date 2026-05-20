"""PackGenerator orchestrator (issue #36 Phase 2).

Composes Stage objects that walk a GenerationOrder through
sourcing → generating → verifying → scoring → dedup → persisting.
This module exposes the public interfaces only; concrete stage
implementations live in `app.orchestrator.stages.*`.
"""

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.pack_generator import PackGenerator, Stage
from app.orchestrator.progress_sink import ProgressSink

__all__ = [
    "OrderContext",
    "PackGenerator",
    "ProgressSink",
    "Stage",
    "StageResult",
]
