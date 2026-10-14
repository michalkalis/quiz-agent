"""Admin trigger for the weekly voice-settings evaluation (#204 task 204.9).

Called by ``.github/workflows/voice-experiment.yml``. ``dry_run=true`` only
reports; ``false`` also writes the decisions to ``voice_experiment_arms``,
which reaches the app through ``GET /app-config`` within about a minute.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query

from ...voice_experiment.evaluator import evaluate
from ..admin import verify_admin_key
from ..deps import get_auth_sessionmaker

router = APIRouter()


@router.post("/admin/voice-experiment/evaluate")
async def evaluate_voice_experiment(
    dry_run: bool = Query(True, description="Report only, change nothing"),
    _: str = Depends(verify_admin_key),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> dict[str, Any]:
    """Per running setting × route: answers and bad captures per arm, the
    chance ON is better/worse, the expected loss of ON, and any decisions."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Database not configured")
    return await evaluate(sessionmaker, dry_run=dry_run)
