# Issue #73 — Stand up Postgres + Redis on mba so quiz-pack-api tests run

**Triage:** chore · resolved

**Status:** **RESOLVED 2026-06-23.** mba's quiz-pack-api gate is durably green (0 failed, twice in
a row). **#72 unblocked.** See **Resolution** below.

## Resolution (2026-06-23)

Standing up Postgres + Redis was necessary but **not sufficient** — the gate had two further,
independent failure modes that the original plan didn't anticipate. All three are now fixed.

**1. Container runtime + stack (the env gap, as planned).** Installed **colima** (headless, no Docker
Desktop) + the `docker compose` CLI plugin on `mba`, booted the existing
`apps/quiz-pack-api/docker-compose.yml` (pgvector/pgvector:pg16 + redis:7, both `healthy`), and
created the `quiz_pack_test` database. `colima` now autostarts on login via `brew services` and the
containers use `restart: unless-stopped`, so the stack survives a reboot.

**2. LLM-gateway leak (newly found).** The integration tests mock canonical provider endpoints
(`api.openai.com`, `api.anthropic.com`) behind an `assert_all_mocked` egress guard, and the
"model unavailable" fail-safes assume **direct** routing. `mba`'s `.env` sets
`LLM_GATEWAY=openrouter` (deliberately — it lacks GOOGLE/ANTHROPIC keys), which points the client at
`openrouter.ai`, so every mock missed → `APIConnectionError` (and the e2e tests' retry/backoff
surfaced as **timeouts**), and the verifier returned a real verdict instead of the 0.0 fail-safe.
Fix: the top-level `tests/conftest.py` now pins `LLM_GATEWAY=direct` for the test session, so the
suite is hermetic and identical on every host (the runtime `.env` is untouched).

**3. `test_orders` not re-runnable + ordering (newly found).** `tests/api/test_orders` used fixed
`transaction_id`s with no cleanup; the orders endpoint is idempotent on `transaction_id`, so a
**second** gate run against the persistent test DB saw the first run's rows and got `200` where `202`
was asserted — i.e. the gate would go green once, then red on every Ralph iteration after. It also
lacked the module-scoped `_alembic_head` fixture its sibling DB-test modules have, so on a fresh
empty DB (collected before `tests/db/`) it ran against unmigrated tables. Fix: added that
`_alembic_head` fixture + an autouse `TRUNCATE generation_orders, generation_jobs … CASCADE` so each
test starts clean and the suite is re-runnable.

**Durability:** folded colima + the compose plugin, a venv sync from declared deps (no more
hand-patching `respx`/`slowapi`/`limits`), and the stack boot + `quiz_pack_test` creation into
`scripts/agent-setup/install.sh` so a fresh `mba` checkout reproduces this without hand-steps.

**Acceptance — met.** On `mba`, the exact Ralph gate command
(`cd apps/quiz-pack-api && ../../.venv/bin/pytest tests/ -q`, no overrides) on a freshly-created
**empty** test DB: **402 passed / 0 failed**, and a second run on the same DB: **402 passed /
0 failed**. Laptop parity: 403 passed / 0 failed twice (1 fewer skip than mba). Containers `healthy`;
colima set to start on login.

**Residual (non-blocking):** `test_order_e2e::test_order_sse_reconnect` timed out **once** across
~6 mba runs (a timing-sensitive SSE test under load) and passed every other time, including both
acceptance runs. Pre-existing flake, not gating; left as-is rather than widening scope.

Commit: `e3e378a` (rebased onto `main` as `fdb8df8`).

---

### Original plan (for reference)

**Blocks #72** (and any quiz-pack-api Ralph work) on `mba`.

## Why

`mba` (the agent Mac that runs Ralph) cannot get the quiz-pack-api test suite green, so the
**per-iteration scoped test gate** (`scripts/ralph/ralph.sh:197` — runs the FULL
`apps/quiz-pack-api` suite, no `-m "not integration"` filter) goes **RED on every iteration**. That
latches `overnight.sh` to gate-red → no push → exit 6. **Any Ralph task that touches quiz-pack-api
(which is most of #72) is therefore blocked on `mba` until this is fixed.**

This is **environment drift**, not a code bug — the same class as `project_dockerfile_drift`. On the
laptop the suite is green because the local Docker stack (`quiz-pack-postgres` + redis on `:5432`/`:6379`)
is up; on `mba` there is **no Docker daemon running, no brew Postgres, no Redis**.

### Mechanism (verified 2026-06-22)

- `apps/quiz-pack-api`'s DB-backed tests **skip only when `DATABASE_URL` is unset**. But `mba`'s repo-root
  `.env` **sets** `DATABASE_URL=postgresql+asyncpg://quiz:quiz@localhost:5432/quiz_pack` and
  `TEST_DATABASE_URL=…/quiz_pack_test`. So instead of skipping, the tests **try to connect to
  `localhost:5432`** → connection refused (nothing listening) → **fail/error** rather than skip.
- Measured on `mba`: `main` itself is **14 failed / 372 passed**; the #72 work branch was **13 failed /
  388 passed** (the #72 commits added only *passing* tests). The ~2 dozen failures are the **DB/integration
  tests — orthogonal to #72**. #72's own logic is clean; the gate just can't distinguish "my change broke
  something" from "this host has no database".
- The 2026-06-22 #72 run *also* surfaced two missing Python deps on `mba` (`respx`, `slowapi`) — already
  hand-synced this session (`respx` 0.23.1, `slowapi` 0.1.10 + `limits`), but that only un-masked the
  deeper Postgres/Redis gap. See **Carry-forward** below.

## The fix — make `mba` mirror the laptop's local dev stack

Run the **existing** `apps/quiz-pack-api/docker-compose.yml` on `mba`:

- `postgres` → `pgvector/pgvector:pg16` (Postgres **with** the pgvector extension the app needs), DB
  `quiz_pack`, user/pass `quiz`/`quiz`, port `5432`, `restart: unless-stopped`.
- `redis` → `redis:7` (ARQ queue + SSE pubsub), port `6379`, `restart: unless-stopped`.

Both already match the `.env` targets. The only thing missing on `mba` is a container runtime + the test
database + migrations.

### Recommended approach: **colima** (headless, no Docker Desktop)

Docker Desktop needs a GUI login + a license (a company-account concern, `feedback_company_accounts`) and is
awkward on a mostly-headless agent Mac. **colima** is a lightweight, API-first Docker runtime that runs under
the agent user's session with no GUI and no license — aligns with `feedback_api_first_tools` and the
"prefer local + project-scoped config" rule. `brew install postgresql@16` is a documented alternative but is
**more** steps (separate `pgvector` install + version-match + `CREATE EXTENSION vector`); the Docker image
bundles a matched pgvector, so it's the lower-friction mirror.

### Exact steps (assume zero prior knowledge — run on `mba`)

1. **Install the runtime** (one-time): `ssh mba`, then `brew install colima docker docker-compose`.
2. **Start the VM** (one-time + on login): `colima start` (defaults are fine; it persists). To survive
   reboots, add `colima start` to login (or `brew services start colima` if available on the tap).
3. **Boot the stack:** `cd /Users/agent/code/quiz-agent/apps/quiz-pack-api && docker compose up -d`. Wait for
   both healthchecks green (`docker compose ps` → `healthy`).
4. **Create the test database** (compose only creates `quiz_pack`; the suite's `TEST_DATABASE_URL` points at
   `quiz_pack_test`): `docker exec quiz-pack-postgres createdb -U quiz quiz_pack_test` (skip if the suite
   auto-creates it — check how the laptop does it first; don't guess).
5. **Run migrations** for both DBs: from `apps/quiz-pack-api`, `alembic upgrade head` (and again with the env
   pointed at `quiz_pack_test` if the fixtures don't migrate it themselves).
6. **Verify acceptance** (below). If green, the Ralph gate can pass on quiz-pack-api work and **#72 is
   unblocked**.

## Carry-forward (already done manually this session — make durable)

- `respx` (0.23.1) + `slowapi` (0.1.10) + `limits` were hand-installed into `mba`'s **root** `.venv` to fix
  `ModuleNotFoundError` during the 2026-06-22 #72 run. These are declared deps (`respx` in
  `[project.optional-dependencies] test`; `slowapi` a runtime dep added by #65) that had drifted out of
  `mba`'s venv.
- **Make this non-recurring:** fold a venv sync into `mba` bootstrap —
  `uv pip install --python .venv/bin/python -e "./apps/quiz-pack-api[test]"` (+ the same for
  `apps/quiz-agent` and `packages/shared`) — so a fresh checkout installs declared deps instead of needing
  hand-patching. Same lesson as `project_dockerfile_drift`: the declared dep list is the source of truth.

## Acceptance

- On `mba`, the **exact command the Ralph gate runs** exits 0:
  `cd /Users/agent/code/quiz-agent && (cd apps/quiz-pack-api && ../../.venv/bin/pytest tests/ -q)` →
  **0 failed** (matching the laptop), no connection-refused errors.
- `docker compose ps` shows `quiz-pack-postgres` + `quiz-pack-redis` **healthy**, and they come back up after
  an `mba` reboot (`restart: unless-stopped` + colima-on-login).
- A subsequent `overnight.sh` iteration on a quiz-pack-api focus reaches the scoped gate **green** (no
  gate-red latch from DB failures).

## Links

- Existing stack: `apps/quiz-pack-api/docker-compose.yml` (pgvector/pgvector:pg16 + redis:7).
- Blocks: [[issue-72-question-fun-engagement-redesign]] (its Phases 0–5 run mostly in quiz-pack-api).
- Launch/oversight prompt for #72 once this lands: `docs/handoffs/handoff-2026-06-23-1018.md`.
- Related env-drift lesson: memory `project_dockerfile_drift`; agent-Mac setup: `project_agent_mac_setup`.
