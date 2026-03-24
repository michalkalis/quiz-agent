"""Client-agnostic REST API for Quiz Agent.

Thin orchestrator that mounts sub-routers from routes/ modules.
All shared state, models, and helpers live in deps.py.
"""

from fastapi import APIRouter

from .routes import sessions, quiz, voice, tts, misc

# Main router with /api/v1 prefix
router = APIRouter(prefix="/api/v1", tags=["Quiz Agent"])

# Mount sub-routers
router.include_router(sessions.router)
router.include_router(quiz.router)
router.include_router(voice.router)
router.include_router(tts.router)
router.include_router(misc.router)
