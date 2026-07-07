# Fly.io Deployment Runbook — quiz-agent

- **Production URL:** https://quiz-agent-api.fly.dev (Fly.io, 3GB persistent volume)
- **Deploy:** `cd apps/quiz-agent && fly deploy`

Read this before deploying or before changing `[[mounts]]` in `apps/quiz-agent/fly.toml`.

## Pitfall 1: Dockerfile pip deps drift from pyproject.toml

`apps/quiz-agent/Dockerfile` (the one deploy uses — `fly deploy -c apps/quiz-agent/fly.toml`
resolves `dockerfile="Dockerfile"` relative to the config file's dir) installs
quiz-agent deps via a hardcoded `RUN pip install fastapi>=... uvicorn>=... ...`
list, NOT from `apps/quiz-agent/pyproject.toml`. Any new dep added to
`pyproject.toml` must also be added to the Dockerfile or prod startup will
`ModuleNotFoundError`.

History: `slowapi`, `sentry-sdk[fastapi]`, `pydub`, `httpx` have all silently
drifted in the past — the next deploy after the change is when it's noticed.

Long-term fix: replace the hardcoded list with `pip install /build/app` to
read from pyproject directly. Shared package install must stay non-editable
(`pip install /build/packages/shared`, not `-e`) for the multi-stage build to work.

## Pitfall 2 (RETIRED 2026-07-07): CHROMA_PATH / mount mismatch

ChromaDB was decommissioned in #41 (Phase B done 2026-07-07): `/data/chroma`
wiped, `CHROMA_PATH` secret unset, code reads only Postgres/pgvector via
`DATABASE_URL`. **The volume `vol_r1l5163d2gjekdz4` (`/data` mount) must
stay** — it holds `ratings.db`, `tts_cache/` (and lazily-created
`translations.db`). Questions live in pgvector; final Chroma backup:
`docs/archive/scripts-chroma/chroma_prod_full_backup_2026-07-07.json`.

Historical note: the CHROMA_PATH/mount mismatch bit twice (2026-04-21,
2026-05-03 — empty DB ~17h). If a `[[mounts]]` change ever breaks the
remaining `/data` consumers, `/api/v1/admin/health` + the `testflight`
pre-flight are the detection points.
