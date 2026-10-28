"""Client-agnostic REST API for Quiz Agent.

Thin orchestrator that mounts sub-routers from routes/ modules.
All shared state, models, and helpers live in deps.py.
"""

from fastapi import APIRouter

from ..monitoring import pack_watch

from .routes import (
    sessions,
    quiz,
    voice,
    dictation,
    tts,
    misc,
    auth,
    entitlements,
    feedback,
    analytics,
    provider_balances,
    question_stock,
    app_config,
    voice_samples,
    voice_experiment,
    daily_challenge,
    rooms,
)

# Main router with /api/v1 prefix
router = APIRouter(prefix="/api/v1", tags=["Quiz Agent"])

# Mount sub-routers
router.include_router(auth.router)
router.include_router(sessions.router)
router.include_router(quiz.router)
router.include_router(voice.router)
router.include_router(dictation.router)
router.include_router(tts.router)
router.include_router(misc.router)
router.include_router(entitlements.router)
router.include_router(feedback.router)
router.include_router(analytics.router)
router.include_router(provider_balances.router)
router.include_router(question_stock.router)
router.include_router(app_config.router)
router.include_router(voice_samples.router)
router.include_router(voice_experiment.router)
router.include_router(daily_challenge.router)
router.include_router(rooms.router)
router.include_router(pack_watch.router)  # #207: pack worker's minute ping
