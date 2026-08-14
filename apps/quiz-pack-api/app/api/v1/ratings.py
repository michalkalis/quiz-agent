"""/v1/ratings — canonical multi-rater question-rating store (issue #154).

Three authorisation regimes on one router, deliberately:

- `POST /batches` and `GET /export` are ADMIN (`require_admin`): creating an
  experiment round and reading the whole dataset are founder operations.
- `GET /batches/{batch_id}` and `PUT /batches/{batch_id}/ratings` are
  UNAUTHENTICATED — the batch UUID *is* the capability (D25: no auth system,
  identity is a name in the URL). Everything reachable with it is already
  blinded; `RatingBatch.mapping` has no code path to a response.
- `POST /` is the in-app path (#155), authorised by the quiz-agent owner JWT
  via `require_user` — the same mechanism the #146 order-retry path uses.

Mounted BARE at `/v1/ratings` (no `/api` alias): a second entry point to the
admin export would be surface for no caller — same reasoning as `appstore.py`.
"""

from __future__ import annotations

import uuid
from typing import Annotated, AsyncIterator, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ...db.models.question import QuestionRow
from ...db.models.rating import Rating, RatingBatch
from ...db.session import get_session
from ..deps import require_admin, require_user
from .ratings_schemas import (
    BatchQuestion,
    BatchViewResponse,
    CreateBatchRequest,
    CreateBatchResponse,
    InAppRatingRequest,
    RatingSavedResponse,
    SavedRating,
    WebRatingRequest,
)
from .ratings_store import export_line, load_batch, original_question_id, upsert_rating

router = APIRouter(prefix="/v1/ratings", tags=["ratings"])


@router.post(
    "/batches",
    response_model=CreateBatchResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_admin)],
)
async def create_batch(
    payload: CreateBatchRequest,
    request: Request,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> CreateBatchResponse:
    """Register a blind rating round; the returned id doubles as its URL token."""
    qids = {q.qid.strip() for q in payload.questions}
    unknown = sorted(set(payload.mapping) - qids)
    if unknown:
        # A mapping keyed by anything other than this batch's blinded ids means
        # the batch was assembled wrong and could never be unblinded again.
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"mapping keys are not blinded qids of this batch: {unknown[:5]}",
        )

    batch = RatingBatch(
        title=payload.title,
        questions=[q.model_dump() for q in payload.questions],
        mapping=payload.mapping,
    )
    session.add(batch)
    await session.commit()

    base = str(request.base_url).rstrip("/")
    return CreateBatchResponse(
        batch_id=batch.id,
        rate_url_template=f"{base}/web/rate/{batch.id}?rater={{rater}}",
    )


@router.get("/batches/{batch_id}", response_model=BatchViewResponse)
async def get_batch(
    batch_id: str,
    session: Annotated[AsyncSession, Depends(get_session)],
    rater: Optional[str] = None,
) -> BatchViewResponse:
    """Blinded questions + this rater's saved ratings (resume across devices)."""
    batch = await load_batch(session, batch_id)

    saved: dict[str, SavedRating] = {}
    name = (rater or "").strip()
    if name:
        rows = await session.execute(
            select(Rating).where(Rating.batch_id == batch.id, Rating.rater == name)
        )
        for r in rows.scalars():
            if r.blinded_qid:
                saved[r.blinded_qid] = SavedRating(
                    score=float(r.score), reason=r.reason, rated_at=r.rated_at
                )

    return BatchViewResponse(
        batch_id=batch.id,
        title=batch.title,
        count=len(batch.questions),
        rater=name or None,
        questions=[BatchQuestion(**q) for q in batch.questions],
        ratings=saved,
    )


@router.put("/batches/{batch_id}/ratings", response_model=RatingSavedResponse)
async def put_web_rating(
    batch_id: str,
    payload: WebRatingRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> RatingSavedResponse:
    """Persist one web rater's score for one blinded question."""
    batch = await load_batch(session, batch_id)

    question = next(
        (q for q in batch.questions if str(q.get("qid")) == payload.qid), None
    )
    if question is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"qid {payload.qid!r} is not in this batch",
        )

    rating_id, rated_at = await upsert_rating(
        session,
        dedupe_key=f"web:{batch.id}:{payload.qid}:{payload.rater}",
        batch_id=batch.id,
        blinded_qid=payload.qid,
        # Unblinded server-side: the rater never sees or sends this.
        question_id=original_question_id(batch, payload.qid),
        question_text=str(question.get("question") or ""),
        rater=payload.rater,
        score=payload.score,
        reason=payload.reason,
        source="web",
    )
    return RatingSavedResponse(
        rating_id=rating_id,
        rater=payload.rater,
        score=payload.score,
        rated_at=rated_at,
    )


@router.post("", response_model=RatingSavedResponse)
async def post_in_app_rating(
    payload: InAppRatingRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    subject: Annotated[str, Depends(require_user)],
) -> RatingSavedResponse:
    """In-app rating (#155): explicit question id, owner JWT as the identity."""
    try:
        question_uuid = uuid.UUID(payload.question_id)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Unknown question"
        ) from None
    question = await session.get(QuestionRow, question_uuid)
    if question is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Unknown question"
        )

    display = (payload.display_name or "").strip()
    rating_id, rated_at = await upsert_rating(
        session,
        dedupe_key=f"inapp:{payload.question_id}:{subject}",
        question_id=payload.question_id,
        question_text=question.question,
        rater=subject,
        score=payload.score,
        reason=payload.reason,
        source="in-app",
        extra={"display_name": display} if display else None,
    )
    return RatingSavedResponse(
        rating_id=rating_id, rater=subject, score=payload.score, rated_at=rated_at
    )


@router.get("/export", dependencies=[Depends(require_admin)])
async def export_ratings(
    session: Annotated[AsyncSession, Depends(get_session)],
) -> StreamingResponse:
    """Whole store as JSONL — the input for the D21 correlation analysis.

    Rows are read inside the handler and streamed from memory rather than
    cursor-streamed: FastAPI closes the request-scoped session before a
    streaming body finishes, and this is a calibration-sized dataset (hundreds
    of rows), so holding a DB cursor open would buy nothing.
    """
    result = await session.execute(select(Rating).order_by(Rating.created_at))
    lines = [export_line(r) for r in result.scalars()]

    async def _body() -> AsyncIterator[str]:
        for line in lines:
            yield line

    return StreamingResponse(
        _body(),
        media_type="application/x-ndjson",
        headers={"Content-Disposition": 'attachment; filename="ratings.jsonl"'},
    )
