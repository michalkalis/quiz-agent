"""Quiz Pack API FastAPI application.

Order-driven quiz pack generation (issue #33): StoreKit JWS-verified orders,
ARQ worker pipeline, SSE progress — plus the legacy admin question
generation/curation tool.

Run with: uvicorn app.main:app --reload --port 8003
"""

import os
from contextlib import asynccontextmanager

# Load environment variables from .env files
try:
    from dotenv import load_dotenv
    # Try multiple locations: current dir, parent dirs, and project root
    base_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.join(base_dir, "../../..")
    load_dotenv(os.path.join(project_root, ".env"))  # Project root .env
    load_dotenv(os.path.join(base_dir, "../../.env"))  # Also check parent
    load_dotenv()  # Current directory .env (overrides others)
except ImportError:
    # python-dotenv not available, skip .env loading
    pass

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

# Structured logging + Sentry before the route modules import (backend arch
# review 2026-07-18). Mirrors quiz-agent's main.py: JSON logs in production,
# DSN-gated Sentry (unset SENTRY_DSN → clean no-op). The arq worker is a
# separate process and runs the same init in worker.on_startup.
from .config import get_settings
from .logging_config import init_sentry, setup_logging

setup_logging()
init_sentry(get_settings().sentry_dsn)

from .api.routes import router
from .api.v1.orders import router as orders_v1_router
from .web.routes import router as web_router
from .rate_limit import limiter


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Create and close the ARQ Redis pool around the process lifetime.

    If Redis is unreachable at startup we keep the app alive — `/health` must
    answer so Fly.io doesn't OOM-loop the machine. `get_arq_pool` retries pool
    creation lazily on the first request that actually needs Redis.
    """
    import logging

    from arq import create_pool
    from arq.connections import RedisSettings

    from .db.migration_check import assert_migrations_at_head

    log = logging.getLogger(__name__)
    settings = get_settings()

    # Backend arch review 2026-07-18: migrations are manual (migrate-before-
    # deploy) — refuse to serve against a schema behind this build's alembic
    # head; the raise fails Fly's health gate and the deploy rolls back. Same
    # check the arq worker runs in worker.on_startup (separate process).
    await assert_migrations_at_head(settings.database_url, log)

    app.state.arq_pool = None
    try:
        app.state.arq_pool = await create_pool(RedisSettings.from_dsn(settings.redis_url))
    except Exception as exc:
        log.warning("ARQ pool unavailable at startup (%s); will retry on demand", exc)
    try:
        yield
    finally:
        if app.state.arq_pool is not None:
            await app.state.arq_pool.close()


# Create FastAPI app. Version convention unified with quiz-agent's FastAPI
# app (service API version "1.0.0"), not the package version in pyproject.
app = FastAPI(
    title="Quiz Pack API",
    description=(
        "On-demand quiz pack generation service: StoreKit JWS-verified orders, "
        "ARQ worker pipeline, SSE progress. Also hosts the legacy admin tool "
        "for generating and curating quiz questions with RAG-based duplicate "
        "detection."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

# Rate limiter (#65): defense-in-depth on the billable generation/verify routes.
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Add CORS middleware — env-driven origins (#65); was allow_origins=["*"].
# Defaults to localhost; set CORS_ORIGINS (comma-separated) per deploy.
cors_origins = os.getenv("CORS_ORIGINS", "http://localhost:3000")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in cors_origins.split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-Admin-Key", "X-StoreKit-JWS", "Authorization"],
)

# Include API routes
app.include_router(router)
# Orders (#95 custom packs): the canonical mount is /api/v1/orders — same
# prefix family as the rest of the API. The bare /v1/orders mount is
# DEPRECATED but kept serving identically: deployed TestFlight iOS clients
# hard-code it (followup: switch iOS to /api/v1/orders, then retire this
# alias). Hidden from OpenAPI so the spec advertises only the canonical path.
app.include_router(orders_v1_router, prefix="/api")
app.include_router(orders_v1_router, include_in_schema=False)
app.include_router(web_router)


@app.get("/")
async def root():
    """Root endpoint."""
    return {
        "name": "Quiz Pack API",
        "version": "1.0.0",
        "web_ui": "http://localhost:8003/web",
        "endpoints": {
            "order_create": "POST /api/v1/orders",
            "order_list_mine": "GET /api/v1/orders",
            "order_status": "GET /api/v1/orders/{order_id}",
            "order_retry": "POST /api/v1/orders/{order_id}/retry",
            "order_stream": "GET /api/v1/orders/{order_id}/stream",
            "web_ui": "GET /web - Admin question management web interface",
            "generate": "POST /api/v1/generate",
            "generate_advanced": "POST /api/v1/generate/advanced",
            "import": "POST /api/v1/import",
            "approve": "POST /api/v1/questions/approve",
            "search": "GET /api/v1/questions/search",
            "duplicates": "POST /api/v1/questions/duplicates",
            "review_pending": "GET /api/v1/reviews/pending",
            "review_submit": "POST /api/v1/reviews/submit",
            "review_stats": "GET /api/v1/reviews/stats",
            "docs": "/docs"
        }
    }


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8003)
