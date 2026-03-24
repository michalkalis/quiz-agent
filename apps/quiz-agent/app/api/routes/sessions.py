"""Session management and multiplayer endpoints."""

import logging
from fastapi import APIRouter, Depends, HTTPException, Request, status

from ..deps import (
    CreateSessionRequest, SessionResponse, AddParticipantRequest,
    get_session_manager, get_usage_tracker,
    session_to_response,
)
from quiz_shared.models.participant import Participant
from ...session.manager import SessionManager
from ...usage.tracker import UsageTracker
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/sessions", response_model=SessionResponse, status_code=status.HTTP_201_CREATED)
@limiter.limit("10/minute")
async def create_session(
    http_request: Request,
    request: CreateSessionRequest,
    session_manager: SessionManager = Depends(get_session_manager),
):
    """Create a new quiz session."""
    try:
        session = session_manager.create_session(
            max_questions=request.max_questions,
            difficulty=request.difficulty,
            user_id=request.user_id,
            mode=request.mode,
            ttl_minutes=request.ttl_minutes,
        )
        session.language = request.language
        if request.category:
            session.category = request.category
        session_manager.update_session(session)
        return session_to_response(session)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to create session: {str(e)}")


@router.get("/sessions/{session_id}", response_model=SessionResponse)
async def get_session(
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
):
    """Get session state."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")
    return session_to_response(session)


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
):
    """Delete a session."""
    success = session_manager.delete_session(session_id)
    if not success:
        raise HTTPException(status_code=404, detail="Session not found")


@router.post("/sessions/{session_id}/extend", response_model=SessionResponse)
async def extend_session(
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
    minutes: int = 30,
):
    """Extend session expiry time."""
    success = session_manager.extend_session(session_id, minutes)
    if not success:
        raise HTTPException(status_code=404, detail="Session not found")

    session = session_manager.get_session(session_id)
    return session_to_response(session)


# Multiplayer

@router.post("/sessions/{session_id}/participants", response_model=Participant)
async def add_participant(
    session_id: str,
    request: AddParticipantRequest,
    session_manager: SessionManager = Depends(get_session_manager),
):
    """Add participant to multiplayer session."""
    participant = session_manager.add_participant(
        session_id=session_id,
        display_name=request.display_name,
        user_id=request.user_id,
    )
    if not participant:
        raise HTTPException(status_code=404, detail="Session not found")
    return participant


@router.delete("/sessions/{session_id}/participants/{participant_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_participant(
    session_id: str,
    participant_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
):
    """Remove participant from session."""
    success = session_manager.remove_participant(session_id, participant_id)
    if not success:
        raise HTTPException(status_code=404, detail="Session or participant not found")
