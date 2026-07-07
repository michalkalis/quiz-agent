"""Question Generator FastAPI application."""

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
    from .config import get_settings

    log = logging.getLogger(__name__)
    settings = get_settings()
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


# Create FastAPI app
app = FastAPI(
    title="Quiz Question Generator",
    description="Admin tool for generating and curating quiz questions with RAG-based duplicate detection",
    version="0.1.0",
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
app.include_router(orders_v1_router)
app.include_router(web_router)


@app.get("/")
async def root():
    """Root endpoint."""
    return {
        "name": "Quiz Question Generator API",
        "version": "0.1.0",
        "web_ui": "http://localhost:8001/web",
        "endpoints": {
            "web_ui": "GET /web - Question management web interface",
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
    uvicorn.run(app, host="0.0.0.0", port=8001)
