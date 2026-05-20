"""Concrete Stage implementations.

Each module here exports one Stage class wrapping an existing collaborator
in `app.{sourcing,generation,verification,scoring}`. Stages land one per
task in Phase 2B (2.4–2.9).
"""

from app.orchestrator.stages.dedup import DedupStage
from app.orchestrator.stages.generation import GenerationStage
from app.orchestrator.stages.persist import PersistStage
from app.orchestrator.stages.scoring import ScoringStage
from app.orchestrator.stages.sourcing import SourcingStage
from app.orchestrator.stages.verification import VerificationStage

__all__ = [
    "DedupStage",
    "GenerationStage",
    "PersistStage",
    "ScoringStage",
    "SourcingStage",
    "VerificationStage",
]
