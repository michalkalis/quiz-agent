# Multi-stage Dockerfile for Quiz Agent API
# Optimized for production deployment on Fly.io

# Stage 1: Builder - Install dependencies
FROM python:3.11-slim as builder

WORKDIR /app

# Install uv for fast dependency management
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Copy shared package first
COPY packages/shared/ packages/shared/

# Copy quiz-agent app
COPY apps/quiz-agent/pyproject.toml apps/quiz-agent/
COPY apps/quiz-agent/app/ apps/quiz-agent/app/
COPY apps/quiz-agent/scripts/ apps/quiz-agent/scripts/

# Install dependencies directly from quiz-agent directory
WORKDIR /app/apps/quiz-agent
RUN uv venv && \
    uv pip install -e ../../packages/shared && \
    uv pip install fastapi uvicorn langchain langchain-openai openai python-multipart requests rich

# Stage 2: Runtime - Minimal production image
FROM python:3.11-slim

WORKDIR /app

# Install runtime dependencies for ChromaDB
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Copy installed dependencies and application from builder
COPY --from=builder /app/apps/quiz-agent/.venv /app/.venv
COPY --from=builder /app/packages /app/packages
COPY --from=builder /app/apps/quiz-agent /app/apps/quiz-agent

# Set Python path and environment
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH="/app" \
    PYTHONUNBUFFERED=1

# Expose port
EXPOSE 8002

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8002/api/v1/health')" || exit 1

# Run pre-generation script then start server
# Note: Pre-generation will gracefully skip if OPENAI_API_KEY is not set
WORKDIR /app/apps/quiz-agent

CMD ["sh", "-c", "python scripts/pregenerate_feedback_audio.py && uvicorn app.main:app --host 0.0.0.0 --port 8002"]
