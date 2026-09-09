"""Miscellaneous endpoints: ElevenLabs tokens, usage/freemium, availability, health."""

import asyncio
import os
import logging
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import text

from ...auth.identity import AuthSubject
from ..deps import (
    ElevenLabsTokenResponse,
    QuestionAvailabilityRequest,
    QuestionAvailabilityResponse,
    UsageResponse,
    get_auth_sessionmaker,
    get_question_retriever,
    get_usage_tracker,
    require_auth_or_grace,
)
from ...retrieval.question_retriever import QuestionRetriever
from ...usage.tracker import UsageTracker
from ...rate_limit import limiter
from quiz_shared.models.session import QuizSession

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/elevenlabs/token", response_model=ElevenLabsTokenResponse)
@limiter.limit("10/minute")
async def get_elevenlabs_token(
    request: Request,
    _auth=Depends(require_auth_or_grace),
):
    """Generate a single-use ElevenLabs token for realtime STT.

    Auth + rate-limited (#65): this mints a real, billable ElevenLabs realtime
    token, so it was the clearest budget-drain vector — previously open with no
    limit. `require_auth_or_grace` blocks anonymous callers (once grace is off) and the
    10/min cap bounds abuse per client IP.
    """
    import httpx

    api_key = os.environ.get("ELEVENLABS_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="ElevenLabs STT not configured (missing ELEVENLABS_API_KEY)",
        )

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe",
                headers={"xi-api-key": api_key},
                timeout=10.0,
            )
            response.raise_for_status()
            data = response.json()

        return ElevenLabsTokenResponse(token=data["token"])

    except httpx.HTTPStatusError as e:
        logger.error(
            "ElevenLabs token mint failed: upstream %s: %s",
            e.response.status_code,
            e.response.text,
        )
        raise HTTPException(
            status_code=502,
            detail=f"ElevenLabs API error: {e.response.status_code}",
        )
    except Exception as e:
        logger.error("Failed to get ElevenLabs token: %s", e, exc_info=True)
        raise HTTPException(
            status_code=502,
            detail="Failed to get ElevenLabs token",
        )


# Usage / Freemium


@router.get("/usage/me", response_model=UsageResponse)
async def get_usage(
    subject: AuthSubject = Depends(require_auth_or_grace),
    usage_tracker: UsageTracker = Depends(get_usage_tracker),
):
    """Usage stats for the bearer subject (questions used, limit, reset time).

    The subject is derived server-side from the bearer token — the same
    identity every write path (session create, RC webhook grants,
    ``/entitlements/sync``) is keyed on. The retired ``/usage/{user_id}``
    variant read whatever id the client put in the path, so the app displayed
    a different account than the one purchases landed on (#96 P1).
    """
    if usage_tracker is None:
        raise HTTPException(status_code=503, detail="Usage tracking unavailable")
    if not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    return await usage_tracker.get_usage(subject.subject_id)


# Corpus availability (pre-flight)


@router.post("/questions/availability", response_model=QuestionAvailabilityResponse)
@limiter.limit("20/minute")
async def get_question_availability(
    request: Request,
    body: QuestionAvailabilityRequest,
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    _subject: AuthSubject = Depends(require_auth_or_grace),
):
    """How many unseen questions this configuration still has (#174 finding 1).

    A 10-question quiz that ended after 3 is the bug this exists to prevent: the
    retriever ran out of unseen questions and `flow.process_answer` silently
    finished the session. The client now asks first and can offer a shorter set
    or a history reset instead of promising a length it cannot deliver.

    Read-only and cheap on purpose — one COUNT, no embedding call, no LLM — so
    it can sit on the tap-to-start path of the quiz hot path.
    """
    # A throwaway session is the input `_build_metadata_filters` takes, and
    # routing through it is what keeps this count honest: the eligibility can
    # never drift from what the retriever actually serves with. Not persisted.
    probe = QuizSession(
        session_id="availability-probe",
        max_questions=body.requested_count,
        current_difficulty=body.difficulty,
        language=body.language,
        include_images=body.include_images,
        category=body.category,
        preferred_categories=body.categories
        or ([body.category] if body.category else []),
    )
    # Same header contract as session creation: TestFlight installs may also see
    # pending_review questions, so their count must include them or the alert
    # would under-report against the corpus they will be served from.
    if request.headers.get("X-Build-Channel") == "testflight":
        probe.build_channel = "testflight"

    available = await question_retriever.count_available(
        probe, client_excluded_ids=body.excluded_question_ids
    )
    return QuestionAvailabilityResponse(
        available=available,
        requested=body.requested_count,
        sufficient=available >= body.requested_count,
    )


# Health


@router.get("/health")
async def health_check(sessionmaker=Depends(get_auth_sessionmaker)):
    """Health check endpoint — gates Fly's rollback, so it must actually probe
    the DB (previously a static dict, so a deploy against an unreachable
    Postgres passed the gate). Cheap ``SELECT 1`` with a short timeout; 503
    fail-loud on error/timeout, same auth sessionmaker the rest of the app
    already depends on (no separate DB-probing logic to maintain)."""
    if sessionmaker is not None:
        try:
            async with sessionmaker() as session:
                await asyncio.wait_for(session.execute(text("SELECT 1")), timeout=3.0)
        except Exception as e:
            logger.error("Health check DB probe failed: %s", e)
            raise HTTPException(
                status_code=503,
                detail=f"Database unreachable: {e}",
            )

    return {
        "status": "healthy",
        "service": "quiz-agent",
        "timestamp": datetime.now().isoformat(),
    }
