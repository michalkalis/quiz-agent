# Multi-stage build for Quiz Agent API
# Build context: repository root (../..)
# Dockerfile location: apps/quiz-agent/Dockerfile

FROM python:3.11-slim as builder

WORKDIR /build

# Install ffmpeg (required by pydub for audio processing)
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*

# Install pip
RUN pip install --no-cache-dir --upgrade pip

# Copy shared package and install it
COPY packages/shared /build/packages/shared
RUN pip install --no-cache-dir /build/packages/shared

# Copy quiz-agent app code
COPY apps/quiz-agent /build/app
WORKDIR /build/app

# Install quiz-agent dependencies.
# Memory project_dockerfile_drift: this list must stay 1:1 with
# apps/quiz-agent/pyproject.toml for any dep imported at boot or by an HTTP
# route. The auth stack (sqlalchemy/asyncpg/alembic/pyjwt/pyattest/cbor2) is pulled
# into the boot path via app/api/deps.py -> app/auth/* — omitting it crash-loops.
# (cbor2 is a direct import in app/auth/app_attest.py; pyattest does NOT pull it transitively.)
RUN pip install --no-cache-dir \
    fastapi>=0.104.0 \
    uvicorn>=0.24.0 \
    openai>=1.0.0 \
    python-multipart>=0.0.6 \
    requests>=2.31.0 \
    rich>=13.0.0 \
    pydub>=0.25.0 \
    httpx>=0.27.0 \
    slowapi>=0.1.9 \
    sentry-sdk[fastapi]>=2.0.0 \
    "sqlalchemy[asyncio]>=2.0.0" \
    asyncpg>=0.29.0 \
    alembic>=1.13.0 \
    "pyjwt[crypto]>=2.8.0" \
    pyattest>=1.0.4 \
    cbor2>=5.6.0 \
    num2words>=0.5.14

# Production stage
FROM python:3.11-slim

WORKDIR /app

# Install ffmpeg (required by pydub for audio processing)
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application code
COPY --from=builder /build/app /app
# Copy migration scripts (for running via fly ssh console)
COPY scripts /scripts

# Create data directory for persistent storage
RUN mkdir -p /data

# Expose port
EXPOSE 8002

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/api/v1/health', timeout=5)"

# Run the application
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
