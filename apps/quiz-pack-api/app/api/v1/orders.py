"""POST /v1/orders + GET /v1/orders/{order_id} (issue #33 Task 1.9).

`POST /v1/orders` authenticates via a StoreKit JWS in the `X-StoreKit-JWS`
header and creates (or idempotently returns) a generation order + job.

`GET /v1/orders/{order_id}` returns the order plus a snapshot of its job; no
auth in Phase 1 (Phase 4 will issue server-side user tokens from first-seen JWS).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sse_starlette.sse import EventSourceResponse

from arq.connections import ArqRedis

from ...db.models.job import GenerationJob
from ...db.models.order import GenerationOrder
from ...db.session import AsyncSessionLocal, get_session
from ...sse import event_stream
from ...sse.jws_cache import verify_jws_cached
from ...storekit import AppleJWSVerifier, JWSError, JWSWrongBundle
from ..deps import get_arq_pool, get_jws_verifier, get_redis_url

router = APIRouter(prefix="/v1/orders", tags=["orders"])

# Server-authoritative product → question count mapping.
_PRODUCT_TIERS: dict[str, int] = {
    "pack_10": 10,
    "pack_20": 20,
    "pack_30": 30,
    "pack_50": 50,
}

_ALLOWED_LANGUAGES = {"en", "sk", "cs"}


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class CreateOrderRequest(BaseModel):
    transaction_id: str
    product_id: str
    prompt: str
    language: str
    target_count: int  # informational; server derives authoritative count from product_id
    category: Optional[str] = None
    theme: Optional[str] = None


class OrderCreatedResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    order_id: uuid.UUID
    status: str
    created_at: datetime


class JobSnapshotResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    job_id: uuid.UUID
    status: str
    progress: int
    retry_count: int
    total_cost_cents: int
    error: Optional[str]
    updated_at: datetime


class OrderSnapshotResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    order_id: uuid.UUID
    status: str
    product_id: str
    target_count: int
    language: str
    category: Optional[str]
    theme: Optional[str]
    created_at: datetime
    delivered_at: Optional[datetime]
    pack_id: Optional[uuid.UUID]
    job: Optional[JobSnapshotResponse]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _validate_guards(body: CreateOrderRequest) -> None:
    """Raise HTTPException for prompt length or language violations."""
    if not (10 <= len(body.prompt.strip()) <= 1000):
        raise HTTPException(
            status_code=422,
            detail="prompt must be between 10 and 1000 characters (after stripping whitespace)",
        )
    if body.language not in _ALLOWED_LANGUAGES:
        raise HTTPException(
            status_code=422,
            detail=f"language must be one of {sorted(_ALLOWED_LANGUAGES)}",
        )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("", status_code=202, response_model=OrderCreatedResponse)
async def create_order(
    body: CreateOrderRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    arq_pool: Annotated[ArqRedis, Depends(get_arq_pool)],
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
    x_storekit_jws: Annotated[Optional[str], Header()] = None,
) -> OrderCreatedResponse:
    """Create a generation order from a verified StoreKit JWS.

    Returns 202 on creation and 200 on idempotent replay (same transaction_id).
    """
    if not x_storekit_jws:
        raise HTTPException(status_code=401, detail="X-StoreKit-JWS header is required")

    # 1. Verify JWS
    try:
        tx = verifier.verify(x_storekit_jws)
    except JWSWrongBundle as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except JWSError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    # 2. Cross-check body vs JWS payload
    if body.transaction_id != tx.transaction_id or body.product_id != tx.product_id:
        raise HTTPException(status_code=400, detail="JWS payload does not match body")

    # 3. Authoritative target_count from product_id
    target_count = _PRODUCT_TIERS.get(body.product_id)
    if target_count is None:
        raise HTTPException(
            status_code=400,
            detail=f"unknown product_id {body.product_id!r}; valid: {sorted(_PRODUCT_TIERS)}",
        )

    # 4. Guards (before any DB write)
    _validate_guards(body)

    # 5. Idempotency check
    stmt = select(GenerationOrder).where(GenerationOrder.transaction_id == body.transaction_id)
    existing = (await session.execute(stmt)).scalars().first()
    if existing is not None:
        return JSONResponse(  # type: ignore[return-value]
            status_code=200,
            content={
                "order_id": str(existing.id),
                "status": existing.status,
                "created_at": existing.created_at.isoformat(),
            },
        )

    # 6. Insert order + job
    order = GenerationOrder(
        transaction_id=body.transaction_id,
        product_id=body.product_id,
        prompt=body.prompt,
        language=body.language,
        target_count=target_count,
        category=body.category,
        theme=body.theme,
        status="pending",
    )
    session.add(order)
    await session.flush()  # get order.id

    job = GenerationJob(order_id=order.id, status="queued")
    session.add(job)
    await session.flush()  # get job.id

    order.job_id = job.id
    await session.flush()

    await session.commit()

    # 7. Enqueue ARQ — after commit so the worker can read the row
    await arq_pool.enqueue_job("process_order", str(order.id))

    # 8. Transition to in_progress
    order.status = "in_progress"
    await session.commit()

    return OrderCreatedResponse(order_id=order.id, status=order.status, created_at=order.created_at)


@router.get("/{order_id}", response_model=OrderSnapshotResponse)
async def get_order(
    order_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> OrderSnapshotResponse:
    """Return order + job snapshot. No auth in Phase 1."""
    stmt = select(GenerationOrder).where(GenerationOrder.id == order_id)
    order = (await session.execute(stmt)).scalars().first()
    if order is None:
        raise HTTPException(status_code=404, detail=f"order {order_id} not found")

    job_snapshot: Optional[JobSnapshotResponse] = None
    if order.job_id is not None:
        job_stmt = select(GenerationJob).where(GenerationJob.id == order.job_id)
        job = (await session.execute(job_stmt)).scalars().first()
        if job is not None:
            job_snapshot = JobSnapshotResponse(
                job_id=job.id,
                status=job.status,
                progress=job.progress,
                retry_count=job.retry_count,
                total_cost_cents=job.total_cost_cents,
                error=job.error,
                updated_at=job.updated_at,
            )

    return OrderSnapshotResponse(
        order_id=order.id,
        status=order.status,
        product_id=order.product_id,
        target_count=order.target_count,
        language=order.language,
        category=order.category,
        theme=order.theme,
        created_at=order.created_at,
        delivered_at=order.delivered_at,
        pack_id=order.pack_id,
        job=job_snapshot,
    )


@router.post("/{order_id}/retry", status_code=202, response_model=OrderCreatedResponse)
async def retry_order(
    order_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
    arq_pool: Annotated[ArqRedis, Depends(get_arq_pool)],
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
    redis_url: Annotated[str, Depends(get_redis_url)],
    x_storekit_jws: Annotated[Optional[str], Header()] = None,
) -> OrderCreatedResponse:
    """Re-enqueue a failed order (M-2).

    Authz: ``X-StoreKit-JWS`` must verify and its ``transaction_id`` must match
    the order's recorded ``transaction_id``. Verification reuses the 60s Redis
    cache from #33 Task 1.11.

    Flow:
        409 if ``order.status != 'failed'``.
        422 if ``job.retry_count >= 3``.
        Otherwise: ``SELECT ... FOR UPDATE`` row-locks order + job (R14 —
        prevents double-enqueue under concurrent retries), resets job to
        ``queued``/``progress=0``/``error=NULL``, increments ``retry_count``,
        flips order to ``pending`` → commit → ARQ enqueue → ``in_progress``.
    """
    if not x_storekit_jws:
        raise HTTPException(status_code=401, detail="X-StoreKit-JWS header is required")

    redis_conn: Redis = Redis.from_url(redis_url, decode_responses=True)
    try:
        try:
            tx = await verify_jws_cached(x_storekit_jws, verifier, redis_conn)
        except JWSWrongBundle as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except JWSError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc
    finally:
        await redis_conn.aclose()

    # Row-lock order: concurrent retries must serialise so we don't double-enqueue
    # (ARQ's own dedup is best-effort, not transactional — see R14).
    order_stmt = (
        select(GenerationOrder).where(GenerationOrder.id == order_id).with_for_update()
    )
    order = (await session.execute(order_stmt)).scalars().first()
    if order is None:
        raise HTTPException(status_code=404, detail=f"order {order_id} not found")

    if order.transaction_id != tx.transaction_id:
        raise HTTPException(
            status_code=403,
            detail="JWS transaction_id does not match this order",
        )

    if order.status != "failed":
        raise HTTPException(
            status_code=409,
            detail=(
                f"order status is {order.status!r}; only 'failed' orders can be retried"
            ),
        )

    if order.job_id is None:
        raise HTTPException(status_code=409, detail="order has no job to retry")

    job_stmt = (
        select(GenerationJob).where(GenerationJob.id == order.job_id).with_for_update()
    )
    job = (await session.execute(job_stmt)).scalars().first()
    if job is None:
        raise HTTPException(status_code=409, detail="order has no job to retry")

    if job.retry_count >= 3:
        raise HTTPException(
            status_code=422,
            detail=f"retry cap reached (retry_count={job.retry_count}, max=3)",
        )

    job.status = "queued"
    job.progress = 0
    job.error = None
    job.retry_count = job.retry_count + 1
    order.status = "pending"
    await session.commit()

    await arq_pool.enqueue_job("process_order", str(order.id))

    order.status = "in_progress"
    await session.commit()

    return OrderCreatedResponse(
        order_id=order.id, status=order.status, created_at=order.created_at
    )


@router.get("/{order_id}/stream")
async def stream_order(
    order_id: uuid.UUID,
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
    redis_url: Annotated[str, Depends(get_redis_url)],
    x_storekit_jws: Annotated[Optional[str], Header()] = None,
    last_event_id: Annotated[Optional[str], Header()] = None,
) -> EventSourceResponse:
    """Stream generation progress as SSE events.

    Authz: ``X-StoreKit-JWS`` must verify to a ``SignedTransaction`` whose
    ``transaction_id`` matches the order's recorded ``transaction_id``.

    ``Last-Event-ID`` header: resume from that event (inclusive-exclusive,
    i.e. only events with ``event_id > Last-Event-ID`` are emitted). Omitting
    the header is treated as ``-1`` — all events replay from the beginning.
    """
    if not x_storekit_jws:
        raise HTTPException(status_code=401, detail="X-StoreKit-JWS header is required")

    # Open a *dedicated* Redis connection for this SSE request (pubsub holds a
    # socket open; we must not reuse the ARQ pool connection).
    redis_conn: Redis = Redis.from_url(redis_url, decode_responses=True)
    try:
        try:
            tx = await verify_jws_cached(x_storekit_jws, verifier, redis_conn)
        except JWSWrongBundle as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except JWSError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc

        # Fetch order to cross-check transaction_id.
        async with AsyncSessionLocal() as session:
            stmt = select(GenerationOrder).where(GenerationOrder.id == order_id)
            order = (await session.execute(stmt)).scalars().first()

        if order is None:
            raise HTTPException(status_code=404, detail=f"order {order_id} not found")

        if order.transaction_id != tx.transaction_id:
            raise HTTPException(
                status_code=403,
                detail="JWS transaction_id does not match this order",
            )

        # Parse Last-Event-ID; sentinel -1 means "replay everything".
        try:
            resume_from = int(last_event_id) if last_event_id is not None else -1
        except ValueError:
            resume_from = -1

    finally:
        # Close the verify-cache connection; event_stream opens its own.
        await redis_conn.aclose()

    return EventSourceResponse(
        event_stream(
            order_id=str(order_id),
            last_event_id=resume_from,
            session_factory=AsyncSessionLocal,
            redis_url=redis_url,
        ),
        headers={"X-Accel-Buffering": "no"},
    )
