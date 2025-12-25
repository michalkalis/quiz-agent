# Multi-stage build for Quiz Agent API
# Build context: repository root
# Dockerfile location: repository root

FROM python:3.11-slim as builder

WORKDIR /build

# Install pip packages
RUN pip install --no-cache-dir --upgrade pip

# Copy shared package first and install it
COPY packages/shared /build/packages/shared
RUN pip install --no-cache-dir -e /build/packages/shared

# Copy quiz-agent files
COPY apps/quiz-agent /build/app
WORKDIR /build/app

# Install quiz-agent dependencies (skip quiz-shared since already installed)
RUN pip install --no-cache-dir \
    fastapi>=0.104.0 \
    uvicorn>=0.24.0 \
    langchain>=0.3.9 \
    langchain-openai>=0.2.10 \
    openai>=1.0.0 \
    python-multipart>=0.0.6 \
    requests>=2.31.0 \
    rich>=13.0.0

# Production stage
FROM python:3.11-slim

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application code
COPY --from=builder /build/app /app
COPY --from=builder /build/packages/shared /packages/shared

# Create data directory for persistent storage
RUN mkdir -p /data/chroma

# Expose port
EXPOSE 8002

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/api/v1/health', timeout=5)"

# Run the application
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
