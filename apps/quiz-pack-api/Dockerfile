# Multi-stage build for quiz-pack-api (issue #33).
# Build context: repository root (../..)
# Dockerfile location: apps/quiz-pack-api/Dockerfile
#
# Memory project_dockerfile_drift: the pip install list below must stay in
# sync with apps/quiz-pack-api/pyproject.toml *for any dep that is imported at
# boot or by an HTTP route*. Heavy deps that are only used by standalone
# scripts in scripts/ + app/image_generation/ (gradio, geopandas, cartopy,
# matplotlib, boto3) are intentionally excluded — they require GIS/system
# packages and aren't reachable from any FastAPI route.

FROM python:3.11-slim as builder

WORKDIR /build

RUN pip install --no-cache-dir --upgrade pip

# Copy and install the shared workspace package first. Non-editable so the
# multi-stage copy of /usr/local/lib/python3.11/site-packages picks it up.
COPY packages/shared /build/packages/shared
RUN pip install --no-cache-dir /build/packages/shared

# Copy quiz-pack-api app code
COPY apps/quiz-pack-api /build/app
WORKDIR /build/app

# Install runtime deps. Versions match apps/quiz-pack-api/pyproject.toml.
RUN pip install --no-cache-dir \
    fastapi>=0.104.0 \
    uvicorn>=0.24.0 \
    langchain>=0.3.9 \
    langchain-openai>=0.2.10 \
    anthropic>=0.42.0 \
    tavily-python>=0.5.0 \
    google-generativeai>=0.8.0 \
    jinja2>=3.1.0 \
    python-multipart>=0.0.6 \
    slowapi>=0.1.9 \
    httpx>=0.27.0 \
    "sqlalchemy[asyncio]>=2.0.30" \
    alembic>=1.13.0 \
    asyncpg>=0.29.0 \
    pgvector>=0.3.0 \
    arq>=0.26.0 \
    redis>=5.0.0 \
    cryptography>=42.0.0 \
    sse-starlette>=2.1.0 \
    pydantic-settings>=2.3.0 \
    pytest-asyncio>=0.23.0

# Production stage
FROM python:3.11-slim

WORKDIR /app

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /build/app /app

EXPOSE 8003

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8003/health', timeout=5)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8003"]
