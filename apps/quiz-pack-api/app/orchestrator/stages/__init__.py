"""Concrete Stage implementations.

Each module here exports one Stage class wrapping an existing collaborator
in `app.{sourcing,generation,verification,scoring}`. Stages land one per
task in Phase 2B (2.4–2.9).
"""

from app.orchestrator.stages.generation import GenerationStage
from app.orchestrator.stages.sourcing import SourcingStage

__all__ = ["GenerationStage", "SourcingStage"]
