# Multi-stage build for quiz-pack-api (issue #33).
# Build context: repository root (../..)
# Dockerfile location: apps/quiz-pack-api/Dockerfile
#
# #207 task 207.24: dependencies come from uv.lock (exact versions + hashes),
# not a hand-copied pip list, so the image ships exactly what CI tested and a
# dep declared in apps/quiz-pack-api/pyproject.toml can no longer be missing
# here (the old "Dockerfile drift" crash-loop). Script-only deps (gradio,
# geopandas, cartopy, matplotlib, deepl) live in the `scripts` extra, which the
# image does not install. Base images are pinned by digest.

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
RUN uv export --locked --no-dev --package quiz-pack-api --no-emit-workspace -o requirements.txt \
    && uv pip install --system --no-deps --require-hashes --compile-bytecode -r requirements.txt

COPY packages/shared packages/shared
RUN uv pip install --system --no-deps --compile-bytecode ./packages/shared

# Production stage
FROM python:3.11.17-slim-trixie@sha256:e88e9763f943ec1834f992a4b51e0f24500486803e8bc534e5767af9ea65f6ce

# Unprivileged runtime user (#207 task 207.24); no volume, so no root step.
RUN useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin app

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

WORKDIR /app
COPY apps/quiz-pack-api /app

# Prompt example corpus (gold standard + anti-patterns). Without it every paid
# pack was generated with no curated exemplars and no anti-pattern block, and
# DedupStage's gold-standard check was a no-op — silently, because the loaders
# fell back to hardcoded examples. `.dockerignore` excludes `data/` but
# re-includes `data/examples/`; if that negation is ever dropped this COPY
# fails the build instead of shipping degraded prompts.
COPY data/examples /app/data/examples

# StoreKit trust anchor: without it every paid order 500s at receipt
# verification. Fail the build rather than ship a pack service that can't sell.
RUN test -f /app/app/storekit/certs/AppleRootCA-G3.cer

# QuestionStorage() opens sqlite:///./data/pending.db at import time.
RUN mkdir -p /app/data && chown app:app /app/data
USER app
ENV HOME=/home/app

EXPOSE 8003

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8003/health', timeout=5)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8003"]
