# Multi-stage build for Quiz Agent API
# Build context: repository root (../..)
# Dockerfile location: apps/quiz-agent/Dockerfile
#
# #207 task 207.24: dependencies come from uv.lock (exact versions + hashes),
# not a hand-copied pip list, so the image ships exactly what CI tested and a
# dep declared in apps/quiz-agent/pyproject.toml can no longer be missing here
# (the old "Dockerfile drift" crash-loop). Base images are pinned by digest;
# bump the digest deliberately (Dependabot proposes it monthly).

FROM python:3.11.17-slim-trixie@sha256:e88e9763f943ec1834f992a4b51e0f24500486803e8bc534e5767af9ea65f6ce AS builder

COPY --from=ghcr.io/astral-sh/uv:0.12.24@sha256:3af4716e991d6956a41e573eab705d0ee08500cd829ed30293eb8472f372c65a /uv /bin/uv

WORKDIR /build

# Workspace manifests + lock only, so the dependency layer stays cached until
# a dependency actually changes.
COPY pyproject.toml uv.lock ./
COPY packages/shared/pyproject.toml packages/shared/
COPY apps/quiz-agent/pyproject.toml apps/quiz-agent/
COPY apps/quiz-pack-api/pyproject.toml apps/quiz-pack-api/

# Into the system interpreter (not a venv) so `fly ssh console` scripts keep
# working with the plain `python` on PATH. Hashes are verified.
RUN uv export --locked --no-dev --package quiz-agent --no-emit-workspace -o requirements.txt \
    && uv pip install --system --no-deps --require-hashes --compile-bytecode -r requirements.txt

COPY packages/shared packages/shared
RUN uv pip install --system --no-deps --compile-bytecode ./packages/shared

# Production stage
FROM python:3.11.17-slim-trixie@sha256:e88e9763f943ec1834f992a4b51e0f24500486803e8bc534e5767af9ea65f6ce

# Install ffmpeg (required by pydub for audio processing)
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*

# Unprivileged runtime user (#207 task 207.24). docker-entrypoint.sh starts as
# root only to hand the root-owned Fly volume (/data) to it, then drops to it.
RUN useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin app

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

WORKDIR /app
COPY apps/quiz-agent /app
# Migration scripts (for running via fly ssh console)
COPY scripts /scripts

# /data = Fly volume mount point; /app/data = main.py's ./data working dir.
RUN mkdir -p /data /app/data && chown app:app /data /app/data

EXPOSE 8002

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/api/v1/health', timeout=5)"

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
