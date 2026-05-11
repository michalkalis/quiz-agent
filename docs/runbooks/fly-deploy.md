# Fly.io Deployment Runbook — quiz-agent

- **Production URL:** https://quiz-agent-api.fly.dev (Fly.io, 3GB persistent volume)
- **Deploy:** `cd apps/quiz-agent && fly deploy`

Read this before deploying or before changing `[[mounts]]` in `apps/quiz-agent/fly.toml`.

## Pitfall 1: Dockerfile pip deps drift from pyproject.toml

The repo-root `Dockerfile` installs quiz-agent deps via a hardcoded
`RUN pip install fastapi>=... uvicorn>=... ...` list, NOT from
`apps/quiz-agent/pyproject.toml`. Any new dep added to `pyproject.toml` must
also be added to the Dockerfile or prod startup will `ModuleNotFoundError`.

History: `slowapi`, `sentry-sdk[fastapi]`, `pydub`, `httpx` have all silently
drifted in the past — the next deploy after the change is when it's noticed.

Long-term fix: replace the hardcoded list with `pip install /build/app` to
read from pyproject directly. Shared package install must stay non-editable
(`pip install /build/packages/shared`, not `-e`) for the multi-stage build to work.

## Pitfall 2: CHROMA_PATH must match fly.toml `[mounts].destination`

Prod ChromaDB lives on Fly volume `vol_r1l5163d2gjekdz4` (3GB). The
`CHROMA_PATH` Fly secret MUST match the `[mounts]` destination in
`apps/quiz-agent/fly.toml` — otherwise the backend writes to the ephemeral
container filesystem and every deploy wipes the DB.

Current correct values (2026-05-03):
- `fly.toml` mount destination: `/data`
- `CHROMA_PATH` secret: `/data/chroma`

This bug has bitten twice (2026-04-21 and 2026-05-03 — empty DB for ~17h
until `CHROMA_PATH` was reset).

After ANY change to `[[mounts]]` in `fly.toml`:
1. Immediately verify `CHROMA_PATH` secret matches the new `destination`.
2. After `fly deploy`, check
   `fly logs -a quiz-agent-api --no-tail | grep "QuestionStore initialized"`
   — the path printed must equal `<mount destination>/chroma`.
3. The `/api/v1/admin/health` endpoint reports `level: critical` +
   `total_approved: 0` when this happens — also surfaced via the
   `testflight` skill's pre-flight check.
4. `fly.toml` references `CHROMA_PERSIST_DIR` (unused by the code) —
   ignore it; the code only reads `CHROMA_PATH`.
