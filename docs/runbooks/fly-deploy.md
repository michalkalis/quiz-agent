# Fly.io Deployment Runbook — quiz-agent

- **Production URL:** https://quiz-agent-api.fly.dev (Fly.io, 3GB persistent volume)
- **Deploy:** `cd apps/quiz-agent && fly deploy`

Read this before deploying or before changing `[[mounts]]` in `apps/quiz-agent/fly.toml`.

## Pitfall 1 (RETIRED 2026-10-16): Dockerfile pip deps drift from pyproject.toml

Both Dockerfiles used to install a hand-copied `pip install ...` list, and a
dep added only to `pyproject.toml` crash-looped prod (`slowapi`, `sentry-sdk`,
`pydub`, `httpx` all drifted). Since #207 task 207.24 the images install from
`uv.lock` (`uv export --locked --package <app>` + hashes) and CI installs the
same lock, so what CI tests is what ships. What remains:

- Change a dependency in `pyproject.toml` → run `uv lock` and commit
  `uv.lock`; an out-of-date lock fails CI and the image build (`--locked`).
- quiz-pack-api script-only deps (gradio, geopandas, cartopy, matplotlib,
  deepl) live in its `scripts` extra, which the image leaves out.
- The app runs as the unprivileged `app` user (uid 10001). quiz-agent's
  `docker-entrypoint.sh` chowns the root-owned `/data` volume at boot, then
  drops privileges; `fly ssh console` still opens a root shell.

## Pitfall 2 (RETIRED 2026-07-07): CHROMA_PATH / mount mismatch

ChromaDB was decommissioned in #41 (Phase B done 2026-07-07): `/data/chroma`
wiped, `CHROMA_PATH` secret unset, code reads only Postgres/pgvector via
`DATABASE_URL`. Questions live in pgvector; final Chroma backup:
`docs/archive/scripts-chroma/chroma_prod_full_backup_2026-07-07.json`.

**No volume since #207.20 step 6 (2026-10-16).** quiz-agent keeps no state on
its machine: sessions, ratings, translations and alert state are in Postgres,
TTS audio in the private R2 bucket `trubbo-tts-cache` (the local
`./data/tts_cache` is a per-machine L1 only). That is what lets one machine
deploy `bluegreen` with no request loss. Any new on-disk store must go to
Postgres or R2, never the machine disk. The old volume
`vol_r1l5163d2gjekdz4` stays detached for a week (rollback: re-add the
`[[mounts]]` block and `TTS_CACHE_DIR = "/data/tts_cache"`, deploy with
`--strategy immediate`), then `fly volumes destroy`.

Historical note: the CHROMA_PATH/mount mismatch bit twice (2026-04-21,
2026-05-03 — empty DB ~17h). If a `[[mounts]]` change ever breaks the
remaining `/data` consumers, `/api/v1/admin/health` + the `testflight`
pre-flight are the detection points.
