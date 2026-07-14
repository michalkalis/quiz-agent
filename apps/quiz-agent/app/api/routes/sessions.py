"""Session management and multiplayer endpoints."""

import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import text

from ..deps import (
    CreateSessionRequest,
    SessionResponse,
    AddParticipantRequest,
    get_auth_sessionmaker,
    get_session_manager,
    get_token_service,
    session_to_response,
)
from quiz_shared.models.participant import Participant
from ...auth.identity import resolve_session_subject
from ...auth.tokens import TokenService
from ...session.manager import SessionManager
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()


async def _require_pack_ownership(pack_id, subject_id, auth_sessionmaker) -> None:
    """Reject unless ``subject_id`` owns the delivered custom pack ``pack_id``.

    Scoping a session to a ``pack_id`` both serves that pack's private, paid
    questions and bypasses the free monthly quota, so a client-supplied id must be
    authorized before it is trusted. Without this an authenticated caller could
    replay any pack id — their own (unmetered play) or a guessed/leaked one to read
    another user's paid pack: an IDOR plus a monetization bypass (#96 review).

    A ``question_packs`` row exists only after successful delivery and carries the
    ordering subject's id (the same JWT ``sub`` space as ``subject_id``), so a row
    matching ``(id, user_id)`` is exactly the ownership predicate. Every failure —
    a malformed id, an un-verifiable (no-DB) environment, or simply no such owned
    pack — answers 404 (never 403) so a caller can neither probe which pack ids
    exist nor distinguish "not yours" from "absent"; the real reason is logged.
    """
    if auth_sessionmaker is None:
        # No auth DB → ownership is un-verifiable. Pack content lives in that same
        # Postgres, so this only happens in a DB-less dev/test env; fail closed.
        logger.warning(
            "Pack ownership unverifiable (no auth DB); denying pack=%s", pack_id
        )
        raise HTTPException(status_code=404, detail="Pack not found")
    try:
        pid = uuid.UUID(str(pack_id))
    except (ValueError, TypeError):
        raise HTTPException(status_code=404, detail="Pack not found")
    async with auth_sessionmaker() as db:
        result = await db.execute(
            text(
                "SELECT 1 FROM question_packs "
                "WHERE id = :pid AND user_id = :uid LIMIT 1"
            ),
            {"pid": pid, "uid": subject_id},
        )
        if result.first() is None:
            logger.warning(
                "Pack ownership denied: subject=%s pack=%s (absent or not owned)",
                subject_id,
                pack_id,
            )
            raise HTTPException(status_code=404, detail="Pack not found")


@router.post(
    "/sessions", response_model=SessionResponse, status_code=status.HTTP_201_CREATED
)
@limiter.limit("10/minute")
async def create_session(
    request: Request,
    body: CreateSessionRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    token_service: TokenService = Depends(get_token_service),
    auth_sessionmaker=Depends(get_auth_sessionmaker),
):
    """Create a new quiz session.

    The subject the session is counted against is derived from the bearer token
    (issue #60.6) — not the client-supplied ``user_id`` — so changing the body
    field can no longer mint a fresh free bucket. During the legacy grace window
    a bearer-less request still falls back to ``body.user_id``.
    """
    subject = await resolve_session_subject(
        request, body.user_id, token_service, auth_sessionmaker
    )
    if subject.subject_id is None:
        # #89 fail-loud invariant: never create a session without a quota
        # subject — a user_id=None session short-circuits every quota gate.
        # resolve_session_subject already rejects the no-identity path; this
        # backstops any future caller that might not.
        raise HTTPException(status_code=401, detail="Authentication required")
    # #96 review — broken-access-control fix: a pack_id both unlocks private paid
    # content and bypasses the free quota, so verify the authenticated subject owns
    # it BEFORE creating the session — and outside the try below, whose broad
    # ``except`` would otherwise turn the 404 into a 500.
    if body.pack_id:
        await _require_pack_ownership(
            body.pack_id, subject.subject_id, auth_sessionmaker
        )
    try:
        session = session_manager.create_session(
            max_questions=body.max_questions,
            difficulty=body.difficulty,
            user_id=subject.subject_id,
            mode=body.mode,
            ttl_minutes=body.ttl_minutes,
        )
        session.language = body.language
        session.include_images = body.include_images
        if body.category:
            session.category = body.category
        # #82: the retriever filters on preferred_categories — session.category
        # was never read there, so the pre-#82 picker was a silent no-op. Wire
        # both the new multi-select list and the legacy single field into it.
        if body.categories:
            session.preferred_categories = body.categories
        elif body.category:
            session.preferred_categories = [body.category]
        # #95: a pack id scopes the whole session to that custom pack (see the
        # retriever + quota bypass). Set last so it is authoritative.
        if body.pack_id:
            session.pack_id = body.pack_id
        session_manager.update_session(session)
        return session_to_response(session)
    except Exception as e:
        raise HTTPException(
            status_code=500, detail=f"Failed to create session: {str(e)}"
        )


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


@router.delete(
    "/sessions/{session_id}/participants/{participant_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def remove_participant(
    session_id: str,
    participant_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
):
    """Remove participant from session."""
    success = session_manager.remove_participant(session_id, participant_id)
    if not success:
        raise HTTPException(status_code=404, detail="Session or participant not found")
