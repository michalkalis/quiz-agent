# Issue 33: quiz-pack-api Phase 1 — domain entities + ordered flow

**Triage:** enhancement · ready-for-agent
**Status:** Plan locked 2026-05-07 from #32 §4 Decisions + post-review revisions (C1/C2/C3 below) + second-pass tightening 2026-05-07 (path/runbook fixes for 1.6/1.7, atomic `step_log` append, ARQ retry mitigation, stub-question Pydantic shape, prompt-length guard, JWS verify cache, structured logging in DoD, R7–R9). Atomic tasks ready for fresh-context execution.
**Created:** 2026-05-07
**Parent:** #32 (umbrella strategy)

---

## Phase 1 scope

**In:** infra (Postgres + pgvector, Upstash Redis), service rename `apps/question-generator/` → `apps/quiz-pack-api/`, SQLAlchemy + Alembic, additive `Question` fields, new entities (`GenerationOrder`, `GenerationJob`, `QuestionPack`), SQLite + ChromaDB → Postgres migration, StoreKit JWS verifier (non-consumable), `POST /v1/orders` + `GET /v1/orders/{id}` + SSE stream, ARQ worker scaffold with stubbed pipeline, Fly two-process-group deploy, end-to-end CI smoke test.

**Out (deferred, with target phase in parens):**
- `PackGenerator` orchestrator + remove duplicate generators (Phase 2).
- OpenAI Moderation, fact-pool cache, per-tier cost cap, Anthropic prompt caching (Phase 3).
- iOS app integration, **subscription tier**, App Store Server Notifications V2 webhook, entitlement state machine (Phase 4).
- Langfuse, DeepEval CI gate, Sentry on quiz-pack-api (Phase 5).
- ChromaDB volume retirement, JSON-on-disk artifact cleanup, admin UI behind `/admin` (Phase 6).

---

## Decisions referenced (from #32 §4) + post-review revisions

Locked from #32 §4 (no change): D2 free-form prompt + Moderation, D3 per-locale generation + cross-lingual reuse, D4 four tiers `10/20/30/50` (best-of-N=5 for 50), D6 single Fly app + two process groups, D7 existing curated content stays `pack_id=NULL`.

Post-review revisions — **this file is the source of truth, supersedes #32 wording**:

- **C1 (new):** **pgvector replaces ChromaDB** for question + pack-prompt embeddings. Reason: Fly volumes are single-attach, so ChromaDB's volume cannot be shared between `web` and `worker` process groups; pgvector also unblocks D5 prompt-cache vector lookup with one DB system. Memory note `project_prod_chroma_mount.md` retired after migration completes (Phase 6).
- **C2 (revision of D1):** **Phase 1 covers non-consumable packs only.** Subscription StoreKit flow + ASSN V2 webhook + entitlement state machine added in Phase 4. `transaction_id` idempotency in Phase 1 = per-purchase only.
- **C3 (revision of D5):** **Cache caches the fact pool, not the question set.** When prompt cosine ≥ 0.92 hits an existing pack, `FactSourcer` reuses cached `fact_ids` but generation runs fresh with reduced `N=2`. Two users with similar prompts get *different* question sets at ~50% LLM cost. Implementation deferred to Phase 3.

---

## Architecture (Phase 1 target)

```
iOS ──POST /v1/orders (JWS, prompt, language, target_count)──▶ web (FastAPI)
                                                                │
                          1) verify JWS (offline ECDSA)         │
                          2) idempotency on transaction_id      │
                          3) insert orders + jobs row           │
                          4) ARQ enqueue ─────────────┐         │
                          5) return 202 + order_id    │         │
                                                      ▼         │
                                              Upstash Redis     │
                                                      │         │
                                                      ▼         │
                                              worker (ARQ)      │
                                                      │         │
                                              process_order:    │
                                                sourcing → ...  │
                                                → done          │
                                                publishes        │
                                                progress to     │
                                                Redis pubsub +  │
                                                step_log JSONB  │
                                                                │
iOS ◀──GET /v1/orders/{id}/stream (SSE)─────────────────────────┘
                                              replays step_log on Last-Event-ID,
                                              then forwards Redis pubsub
                                              channel `order:{id}:progress`
```

Storage:
- Postgres (Fly Postgres): `questions`, `generation_orders`, `generation_jobs`, `question_packs`. Replaces SQLite `pending.db`.
- pgvector: `questions.embedding`, `question_packs.prompt_embedding`. Replaces ChromaDB.
- Upstash Redis: ARQ queue + SSE pubsub.
- **No Fly volumes.** Both processes are stateless.

---

## Tasks

### Task 1.1 — Provision Postgres (pgvector) + Upstash Redis

- Fly Postgres: `quiz-pack-db`, region `cdg`, `shared-cpu-1x` **1024 MB** (revised — see Status note below).
- Run `CREATE EXTENSION vector;` in the `quiz_pack` app database (matches local docker-compose DB name).
- Upstash Redis (free tier).
- Add as Fly secrets to the new app (created in 1.2): `DATABASE_URL`, `REDIS_URL`. Local dev: `.env` per memory `feedback_secrets_management`.
- Document local setup in `apps/quiz-pack-api/README.md`. Provide a `docker-compose.yml` (`pgvector/pgvector:pg16` + `redis:7`) and a `make dev` (or equivalent) target that boots compose + `uvicorn` + `arq` worker in one command.

**Acceptance.** `psql $DATABASE_URL -c "SELECT extname FROM pg_extension WHERE extname='vector';"` returns one row; `redis-cli -u $REDIS_URL ping` returns `PONG`; `make dev` (or documented equivalent) boots the full local stack and `curl localhost:8003/health` returns 200.

**Status: done 2026-05-07.** Resolved deviations from the plan:

1. **Postgres tier bumped 256 MB → 1024 MB.** The 256 MB tier OOMs `apt-get install postgresql-17-pgvector` during the custom-image build (peak RSS ≈ 350 MB). 1 GB is the smallest tier that builds reliably; cost diff ≈ $5/mo, accepted. R7 in the risk register has been rewritten — the 256 MB-specific `maintenance_work_mem` workaround is no longer the primary mitigation (1 GB has 256 MB default), but the explicit `SET` in 1.7 stays as a belt-and-braces.
2. **Custom Postgres image required.** Default `flyio/postgres-flex:17.2` lacks the `pgvector` apt package, and runtime `apt install` does not persist (immutable container, overlay fs wiped on machine restart). The image source lives in [`infra/quiz-pack-db/`](../../infra/quiz-pack-db/) and is published as `registry.fly.io/quiz-pack-db:pgvector-0.8.2`. Alternatives evaluated and rejected: `fly mpg` Basic (~$38/mo), Supabase (platform change).
3. **App DB name is `quiz_pack`.** Local docker-compose creates `quiz_pack`; prod was initially provisioned with only the default `postgres` DB. Decision: create `quiz_pack` on prod for parity, so `DATABASE_URL` ends `/quiz_pack` in both environments.

### Task 1.2 — Rename `apps/question-generator` → `apps/quiz-pack-api` + Dockerfile parity

- `git mv apps/question-generator apps/quiz-pack-api`. Update `pyproject.toml` package name + setuptools includes.
- Update CLAUDE.md quick-reference table (port 8003 unchanged).
- New `apps/quiz-pack-api/Dockerfile` mirroring `apps/quiz-agent/Dockerfile`, build context = repo root (so `packages/shared` is reachable). Per memory `project_dockerfile_drift`: pip install list **must match `pyproject.toml` exactly**. New deps to add now: `sqlalchemy[asyncio]`, `alembic`, `asyncpg`, `pgvector`, `arq`, `redis`, `cryptography`, `sse-starlette`, `pydantic-settings`.
- New `apps/quiz-pack-api/fly.toml`: app `quiz-pack-api`, web process group only in 1.2 (`uvicorn app.main:app --host 0.0.0.0 --port 8003`). The `worker = "arq app.worker.WorkerSettings"` process group stays commented out in `fly.toml` until **Task 1.10** wires `app.worker.WorkerSettings` — deploying a worker with no settings module would crash-loop the machine. **No `[[mounts]]`**.

**Acceptance.** Local `uvicorn` boots from new path; `fly deploy -c apps/quiz-pack-api/fly.toml` ships the web process; `fly status -a quiz-pack-api` shows web healthy; existing `/api/v1/generate` still 200s (no behaviour change yet). Worker process group acceptance moves to Task 1.10.

### Task 1.3 — SQLAlchemy + Alembic skeleton, async session

- New module `apps/quiz-pack-api/app/db/`:
  - `engine.py` — `create_async_engine(DATABASE_URL, pool_size=5)`.
  - `session.py` — `AsyncSession` factory + FastAPI `get_session` dependency.
  - `base.py` — `DeclarativeBase` superclass + UUID PK mixin.
- `apps/quiz-pack-api/alembic/` — `alembic init`, `env.py` reads `DATABASE_URL`, autogenerate enabled. First (empty) migration commits the directory layout.
- `tests/conftest.py` — pytest-asyncio fixture using `TEST_DATABASE_URL` (a local Postgres or testcontainers — pick whichever the developer already has running).

**Acceptance.** `pytest tests/db/test_smoke.py` opens a session and runs `SELECT 1`; `alembic upgrade head` is idempotent on a fresh DB.

**Status: done 2026-05-07.** Notes:

1. **DATABASE_URL scheme normalization in `app/db/engine.py`.** The Fly secret is libpq-form (`postgres://`); `normalize_async_url` rewrites `postgres://` and bare `postgresql://` → `postgresql+asyncpg://` at engine-build time. `psql $DATABASE_URL` ergonomics stay intact, no need to maintain two secrets. Unit-tested in `tests/db/test_smoke.py::test_normalize_async_url_rewrites_libpq`.
2. **Baseline migration enables `pgvector`.** The init revision (`29f509ffa769`) runs `CREATE EXTENSION IF NOT EXISTS vector` so any environment (CI, test DB, prod) bootstraps via `alembic upgrade head` alone — independent of the local `db/init/01-vector.sql` script. **Forward-only policy** (R8) documented in the `alembic/env.py` header.
3. **`pytest-asyncio` added to BOTH `pyproject.toml` and `Dockerfile`** per memory `project_dockerfile_drift`. `pyproject.toml` also picks up `asyncio_mode = "auto"` so tests don't need explicit `@pytest.mark.asyncio` everywhere.
4. **Local test DB.** `quiz_pack_test` created on the docker-compose Postgres alongside `quiz_pack`; conftest fixture targets `TEST_DATABASE_URL` (falls back to `DATABASE_URL` so CI doesn't need a separate var).

### Task 1.4 — `Question` Pydantic field additions + typed `GenerationProvenance`

Edit `packages/shared/quiz_shared/models/question.py` — additive only, every new field `Optional`:

- `pack_id: Optional[str] = None` (NULL = global library, per D7). UUID-as-string in Pydantic, UUID type in ORM (1.5).
- `language: Optional[str] = None` (BCP-47).
- `prompt_seed: Optional[str] = None` — deterministic hash `sha256(prompt + language + category + theme)[:16]` of the inputs that produced this question. Used in Phase 3 (C3) to group fact-pool cache hits and in Langfuse traces (Phase 5) to correlate questions back to the originating order without exposing the raw prompt.
- `embedding_model: Optional[str] = None`, `embedding_dim: Optional[int] = None`.
- `cost_cents: Optional[int] = None`.

Promote `generation_metadata: Dict[str, Any]` to a typed `GenerationProvenance` sub-model **with a lossless fallback**:

```python
class GenerationProvenance(BaseModel):
    model: Optional[str] = None
    provider: Optional[str] = None
    prompt_version: Optional[str] = None
    pipeline: Optional[str] = None  # "fact_first" | "v2_cot" | "themed" | "kids"
    generation_temperature: Optional[float] = None
    critique_model: Optional[str] = None
    critique_score: Optional[float] = None
    reasoning_pattern: Optional[str] = None
    fact_ids: List[str] = Field(default_factory=list)
    extra: Dict[str, Any] = Field(default_factory=dict)  # captures unknown keys, lossless
    created_at: Optional[datetime] = None
```

`Question.from_dict` parses legacy dict → `GenerationProvenance` (unknown keys land in `extra`, so old data round-trips). iOS `Question.swift` gets the new optional fields per `/verify-api` workflow — **Codable parity only, no iOS UX change in Phase 1** (the orders flow ships in Phase 4).

**Acceptance.** All existing tests in `apps/quiz-agent/tests/` and `apps/quiz-pack-api/tests/` pass; new tests cover legacy-dict round-trip; `/verify-api` confirms iOS Codable.

**Status: done 2026-05-07.** Notes:

1. **`generation_metadata` is now `Optional[GenerationProvenance]`.** Legacy free-form dicts still construct cleanly: a `model_validator(mode='before')` on `GenerationProvenance` routes known keys to typed fields and drops everything else into `extra` so old data round-trips losslessly. `Question.get_ai_score()` reads `critique_score` first, then falls back to `extra["ai_score"]`.
2. **Callsites that mutated the field as a dict** (`apps/quiz-pack-api/app/generation/advanced_generator.py:170-176`, `:264-271`) now build/copy `GenerationProvenance` instances directly. `question_store._question_to_metadata` serialises via `model_dump_json()`; the deserialise path is unchanged because Pydantic auto-coerces dict → typed.
3. **iOS Codable parity** (`apps/ios-app/Hangs/Hangs/Models/Question.swift`): added `language`, `packId`, `promptSeed`, `embeddingModel`, `embeddingDim`, `costCents` as optional fields with snake_case `CodingKeys` and trailing `= nil` init defaults — existing call sites compile unchanged. No iOS UX surface in Phase 1 (per plan).
4. **Coverage**: 16 new tests in `apps/quiz-pack-api/tests/test_question_provenance.py` exercise legacy-dict round-trip, typed-field routing, `get_ai_score` fallback, and the six new optional `Question` fields. All `apps/quiz-agent/tests/` pass; the only red tests in repo (`tests/db/test_smoke.py`, `tests/test_translation_validation.py`) are pre-existing infra/network issues unrelated to this change.

### Task 1.5 — SQLAlchemy ORM + Alembic migration for the four tables

Pydantic stays the wire/domain layer; SQLAlchemy is persistence; explicit `to_pydantic()` / `from_pydantic()` at the seam.

ORM tables in `apps/quiz-pack-api/app/db/models/`:

```
questions
  id (uuid pk), question, type, possible_answers (jsonb),
  correct_answer (jsonb), alternative_answers (jsonb),
  topic, category, difficulty, tags (jsonb), language_dependent (bool),
  age_appropriate, language, pack_id (uuid fk nullable),
  prompt_seed, provenance (jsonb), source, source_url, source_excerpt,
  review_status, embedding (vector(1536)), embedding_model, embedding_dim,
  cost_cents, usage_count, created_at, expires_at, freshness_tag
  indexes:
    - ivfflat on embedding (lists=100) using vector_cosine_ops
    - btree (pack_id) WHERE pack_id IS NOT NULL
    - btree (language, category, review_status)

generation_orders
  id (uuid pk), user_id, transaction_id (text unique),
  product_id, prompt, category, theme,
  target_count (int), language,
  status (enum: pending|in_progress|delivered|failed|refunded),
  job_id (uuid fk nullable), pack_id (uuid fk nullable),
  created_at, delivered_at, refund_eligible (bool)

generation_jobs
  id (uuid pk), order_id (uuid fk),
  status (enum: queued|sourcing|generating|critiquing|verifying|scoring|persisting|done|failed),
  progress (smallint 0..100),
  step_log (jsonb),  -- append-only array of {event_id, step, started_at, finished_at, info}
  total_cost_cents (int), retry_count (int), error,
  created_at, updated_at

question_packs
  id (uuid pk), order_id (uuid fk), user_id,
  name, description, prompt, prompt_embedding (vector(1536)),  -- for D5/C3 cache (Phase 3)
  category, theme, language,
  generated_at, actual_count (int), target_count (int)
```

Helpers:
- `append_step(job_id, step, info) -> event_id` — must be a single SQL statement so concurrent writers can't lose events: `UPDATE generation_jobs SET step_log = step_log || $1::jsonb, updated_at = now() WHERE id = $2 RETURNING jsonb_array_length(step_log) - 1 AS event_id`. The new entry's `event_id` is computed inside the same statement (last index of the appended array), guaranteeing monotonicity per job. Naïve read-modify-write of `step_log` in Python is a race — do not load and re-write.
- Status fields use **VARCHAR + CHECK constraint** (`status TEXT NOT NULL CHECK (status IN ('queued','sourcing',...))`), not Postgres native `CREATE TYPE`. Trade-off: native enums give nicer `\d` output but `ALTER TYPE ... ADD VALUE` is forward-only and pre-PG12 can't run inside a transaction — adding a status in Phase 2/3 would be unnecessarily painful. CHECK constraints are trivial to alter via Alembic. Schema sketches above use `enum:` informally to describe values, not implementation.
- All time columns (`created_at`, `updated_at`, `delivered_at`, `expires_at`, `generated_at`) are `TIMESTAMPTZ` in Postgres and `datetime` with explicit `timezone.utc` in Python. No naïve datetimes anywhere.
- `question_packs.actual_count` is written by the worker on `persisting → done` (1.10), not by the API.

**Acceptance.** `alembic upgrade head` creates all tables; round-trip test (Pydantic → ORM → Pydantic) is value-equal; smoke test asserts index existence via `pg_indexes`; concurrent-append test fires 50 parallel `append_step` calls against one job and asserts `len(step_log) == 50` with all `event_id` values present and unique.

**Status: done 2026-05-11.** Notes:

1. **ORM under `app/db/models/`** — one file per table (`question.py`, `order.py`, `job.py`, `pack.py`) plus `__init__.py` that re-exports everything and is in turn re-exported from `app/db/__init__.py`, so `import app.db` registers all four tables on `Base.metadata` without explicit walks. Pydantic↔ORM seam (`question_to_row` / `row_to_question`) lives next to the table it converts (`app/db/models/question.py`) — explicit field-by-field mapping, no `model_dump()` shortcut.
2. **ORM class is `QuestionRow`, not `Question`** — Pydantic `Question` keeps that name across the codebase, so the persistence shape is named `QuestionRow` to keep the seam unambiguous at call sites.
3. **`append_step` SQL — single statement, no read-modify-write.** `step_log = step_log || jsonb_build_array(jsonb_set(:payload::jsonb, '{event_id}', to_jsonb(jsonb_array_length(step_log))))`. `step_log` on the right of `SET` evaluates against the OLD row, so `jsonb_array_length(step_log)` is the new entry's index; `RETURNING jsonb_array_length(step_log) - 1` reads the NEW row and yields the same value. Concurrent UPDATEs serialise on the row lock — verified by the 50-call concurrency test.
4. **Circular FK orders ↔ jobs/packs** handled via SQLAlchemy `use_alter=True` on `generation_orders.job_id` and `pack_id`. Migration order: create `generation_orders` without those FKs → create `generation_jobs`, `question_packs`, `questions` → `ALTER TABLE generation_orders ADD CONSTRAINT fk_orders_job_id/pack_id`. Forward-only per R8.
5. **Status enums = `VARCHAR + CHECK`** per plan trade-off (`ALTER TYPE ... ADD VALUE` is forward-only pre-PG12 and can't run in a transaction; CHECK is trivial to alter via Alembic). Constants `ORDER_STATUSES`, `JOB_STATUSES`, `REVIEW_STATUSES` exported alongside their ORM classes so app code references one source of truth.
6. **Indexes built in the migration**: ivfflat `vector_cosine_ops` on `questions.embedding` (`lists=100`), partial btree on `questions.pack_id WHERE pack_id IS NOT NULL`, composite btree on `(language, category, review_status)`. Test asserts existence via `pg_indexes` AND the ivfflat indexdef contains `ivfflat` + `vector_cosine_ops`.
7. **Test infra** — `tests/db/test_core_entities.py` runs `alembic upgrade head` in a module-scoped autouse fixture so a fresh test DB bootstraps without manual setup. Six tests cover: full + minimal Pydantic round-trip, index existence + ivfflat indexdef, 50-call concurrent `append_step`, CHECK-constraint rejection of bogus status, and orders ↔ packs FK link round-trip. Updated the pre-existing smoke test's hard-coded head-revision assertion (`29f509ffa769` → `1c5e0fa7b3d4`).
8. **Float-precision caveat**: pgvector stores `Vector(n)` as float32, so list[float] round-trip loses ~6 decimal digits of precision. Round-trip test compares `embedding` separately via `pytest.approx(abs=1e-6)` and clears it before the model-level equality check — documented in the test docstring.

### Task 1.6 — SQLite `pending.db` → Postgres migration

- New script `apps/quiz-pack-api/scripts/migrate_pending_to_postgres.py`.
- **Per memory `feedback_qgen_import_cwd`**: read SQLite from configurable paths via `--sqlite-path` (repeatable). Defaults search **post-rename** locations: `apps/quiz-pack-api/pending.db` and root-cwd `pending.db`. Dedupe by `Question.id`. Note: 1.2's `git mv` moves the historical `apps/question-generator/pending.db` to `apps/quiz-pack-api/pending.db`; the old path no longer exists by the time this script runs.
- **Prod migration mechanism.** Prod `pending.db` lives on the existing `quiz-agent` Fly volume (or wherever `feedback_qgen_import_cwd` cached it). Pick one approach in the runbook:
  - (a) `fly ssh sftp get` from `quiz-agent` to local, run script locally with `--sqlite-path ./prod_pending.db --database-url $PROD_DATABASE_URL`.
  - (b) Run script as a one-shot `fly machine run` on `quiz-pack-api` with the volume temporarily attached read-only.
  Document the chosen approach in the script docstring.
- Build Pydantic `Question` per row, fill defaults: `language="en"`, `pack_id=None`, `embedding_model="text-embedding-3-small"`, `embedding_dim=1536`. Populate `prompt_seed` from the defined hash if inputs are reconstructable, else leave `None`.
- Embed any row missing a cached embedding (OpenAI `text-embedding-3-small`, **batched at 100 inputs per request**); persist to `questions.embedding`.
- `--dry-run` prints per-source counts and intended writes; `--execute` performs them. Idempotent on `questions.id`.
- **Migration runbook**: freeze `/import` writes for the duration (≤ 5 min); document in script docstring.

**Acceptance.** Dry-run counts == `sqlite3 ... "SELECT COUNT(*) FROM pending_questions"` summed across both files; second `--execute` produces 0 inserts; `SELECT count(*) FROM questions WHERE embedding IS NULL` = 0.

**Status: done 2026-05-11.** Implementation notes:

1. **Script:** `apps/quiz-pack-api/scripts/migrate_pending_to_postgres.py` — async SQLAlchemy via `app.db.engine`, OpenAI batch embeddings (size configurable via `--batch-size`, default 100), `pg_insert(...).on_conflict_do_nothing(index_elements=["id"])` for idempotent inserts.
2. **Default SQLite paths:** `apps/quiz-pack-api/pending.db`, `apps/quiz-pack-api/data/pending.db`, `./pending.db`. The `data/` entry was added to match the current question-generator's actual on-disk location (the plan sketch assumed bare `pending.db` post-rename).
3. **Legacy-id mapping (R2 dedupe).** Pydantic `Question.id` was historically a short string like `kids_22`; the Task 1.5 seam refuses non-UUID ids. The script derives a stable `uuid5(NAMESPACE_LEGACY_PENDING, "pending:<legacy_id>")` so the same input always produces the same Postgres row id — second `--execute` is 0 inserts without needing a SELECT-then-INSERT race. Original id preserved at `provenance.extra.legacy_id` for traceability.
4. **Runbook chosen.** Approach (a) `fly ssh sftp get` from `quiz-agent` to local, run script locally against `$PROD_DATABASE_URL`. Documented in the script module docstring. Approach (b) `fly machine run` rejected — adds infra friction for a one-shot migration.
5. **Acceptance verified locally.** `apps/quiz-pack-api/data/pending.db` had 1 row (`kids_22`, koala fingerprints). Dry-run reported `Would insert: 1, Need embedding: 1`. After `--execute`: `Inserted: 1`. Second `--execute`: `Inserted: 0`. `SELECT count(*) WHERE embedding IS NULL` = 0. `provenance->'extra'->>'legacy_id'` round-trips to `kids_22`.
6. **Defaults filled on each row.** `language="en"`, `pack_id=None`, `embedding_model="text-embedding-3-small"`, `embedding_dim=1536`. `prompt_seed` left at JSON value (None for legacy rows — inputs not reconstructable, per plan).

### Task 1.7 — ChromaDB approved questions → Postgres+pgvector migration

- New script `apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py`.
- Reads ChromaDB at `--chroma-path` (local default: `apps/quiz-agent/chroma_data/`).
- **Prod migration mechanism.** The ChromaDB volume is mounted on `quiz-agent`, not `quiz-pack-api`. Pick one approach in the runbook:
  - (a) **Run from inside `quiz-agent`** via `fly ssh console -a quiz-agent`, with `DATABASE_URL` exposed as a secret on `quiz-agent` for the migration window only (then revoke).
  - (b) **Tarball + local run**: `fly ssh sftp` ChromaDB to a local directory, run script locally against prod `DATABASE_URL`.
  Document the chosen approach in the script docstring + migration runbook.
- Before the index build, set `SET maintenance_work_mem = '128MB';` in the script's session (see 1.1 caveat / R7) to avoid OOM during `CREATE INDEX ... USING ivfflat`.
- For each question: build Pydantic `Question` from ChromaDB metadata + document, copy embedding into `questions.embedding`, set `review_status='approved'`, `pack_id=None`.
- Idempotent on `questions.id`.
- **Read-path cutover for `quiz-agent`** (switching from ChromaDB to Postgres+pgvector for question retrieval) is **deferred** — voice quiz keeps reading from ChromaDB through Phase 1. Both stores are live; Postgres is the new write path.

**Acceptance.** Local: ChromaDB count == `SELECT count(*) FROM questions WHERE pack_id IS NULL AND review_status='approved'`. Prod: same equality, verified via `fly ssh`. Voice quiz regression suite (`apps/quiz-agent/tests/`) green.

**Status: code complete 2026-05-12, prod migration pending.** Implementation notes:

1. **Script:** `apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py` — async SQLAlchemy via `app.db.engine`, paginated read from ChromaDB via `collection.get(limit=500, offset=…)` so a large prod volume doesn't load everything into RAM. Embeddings are copied straight across — no re-embed, no OpenAI calls, no cost (the ChromaDB-cached vectors are already `text-embedding-3-small` 1536-d).
2. **ID parity with 1.6.** The script imports `_legacy_to_uuid` and the `NAMESPACE_LEGACY_PENDING` namespace from `migrate_pending_to_postgres` directly. A question whose legacy id is `kids_42` resolves to the same Postgres UUID in both migrations, so a question that lived in both stores collides on one row instead of duplicating. Verified via `_legacy_to_uuid("kids_42") == legacy16("kids_42")`.
3. **ON CONFLICT DO UPDATE, not DO NOTHING.** 1.6 uses `DO NOTHING` because pending rows are pre-approval; 1.7 is authoritative for `review_status='approved'`. On id collision the script overwrites `review_status, pack_id, question, embedding, embedding_model, embedding_dim, provenance` — i.e. ChromaDB wins for those columns. This lets the acceptance test pass even when 1.6 already inserted a row with `review_status='pending_review'`.
4. **Metadata → Question conversion** reuses `ChromaDBQuestionStore._metadata_to_question` (already the single source of truth for that mapping in `packages/shared`). The script only overrides `review_status='approved'`, `pack_id=None`, and defaults `language='en'` for legacy rows that didn't track it.
5. **Runbook chosen.** Approach (a) `fly ssh sftp get` from `quiz-agent` to local, run script locally against `$PROD_DATABASE_URL`. Documented in the script module docstring. Consistent with 1.6 — approach (b) `fly ssh console` inside `quiz-agent` with cross-app `DATABASE_URL` was rejected for the same one-shot-friction reason.
6. **R7 belt-and-braces.** Script issues `SET maintenance_work_mem = '128MB'` before the bulk upsert. The ivfflat index is already built (1.5 migration); the SET only matters if Postgres rebuilds/reindexes mid-bulk, but it's free and the plan calls for it.
7. **Dockerfile excludes chromadb deliberately.** Per `apps/quiz-pack-api/Dockerfile` comment, heavy script-only deps (chromadb included) are excluded from the prod image — they aren't reachable from any FastAPI route. The script imports chromadb lazily and prints a clear error if it's missing, so prod (approach a) runs locally where the workspace has chromadb installed via `quiz-shared`.
8. **Provenance stamped.** Legacy chroma id preserved at `provenance.extra.legacy_id` + `legacy_source="chroma"` so a future audit can trace each Postgres row back to its ChromaDB origin without a separate mapping table.
9. **Local acceptance pending real data.** The local `apps/quiz-agent/chroma_data/` is empty (count=0). Smoke check `_build_question` against synthetic metadata returns a valid `Question` with the right overrides and a 1536-d embedding. Full acceptance (`count == SELECT count(*) WHERE pack_id IS NULL AND review_status='approved'`) runs on prod data after the sftp pull. **Voice quiz regression suite still reads ChromaDB through Phase 1** (read-path cutover is Phase 2), so this script is a one-shot copy, not a dual-write.

### Task 1.8 — StoreKit JWS verifier (non-consumable scope)

- New module `apps/quiz-pack-api/app/storekit/`:
  - `verifier.py` — `AppleJWSVerifier.verify(jws: str) -> SignedTransaction`. Offline ECDSA P-256 against Apple's root chain (cert bundled at `app/storekit/certs/AppleRootCA-G3.cer`).
  - `models.py` — Pydantic `SignedTransaction` with at minimum: `transaction_id`, `original_transaction_id`, `product_id`, `purchase_date`, `bundle_id`, `environment` (`Sandbox` | `Production`). Subscription-only fields (`expiresDate`, `inAppOwnershipType`, `revocationReason`) parsed but **not enforced** in Phase 1 — present for forward compat, ignored by code.
  - `exceptions.py` — `JWSInvalid`, `JWSExpired`, `JWSWrongBundle`.
- Reject if `bundle_id != settings.APP_BUNDLE_ID` or `environment != settings.STOREKIT_ENVIRONMENT` (per-deploy: `Sandbox` for staging Fly app, `Production` for prod).

**Acceptance.** Unit tests with sample JWSs (sandbox + production) verify successfully; tampered payload raises `JWSInvalid`; wrong bundle raises `JWSWrongBundle`; cert validity > 90 days from now (assertion in CI to catch rotation early).

**Status: done 2026-05-12.** Notes:

1. **Module layout:** `apps/quiz-pack-api/app/storekit/{__init__.py, exceptions.py, models.py, verifier.py, certs/README.md}`. Exceptions, models, and `AppleJWSVerifier` re-exported from `app.storekit` so Task 1.9 can `from app.storekit import AppleJWSVerifier, JWSInvalid, JWSWrongBundle, SignedTransaction` without reaching into submodules.
2. **Environment-mismatch exception choice.** Plan listed `JWSInvalid` / `JWSExpired` / `JWSWrongBundle`. Bundle mismatch (security signal — JWS for a different app) keeps its own type; **environment mismatch (config drift — sandbox build hit prod or vice versa) raises `JWSInvalid` with `"environment mismatch"` in the message**. Trade-off: matches plan letter (3 exceptions) but loses a clean type for the dev/prod misconfig case. Acceptable for Phase 1 since each Fly app is single-environment and the message string is greppable in Sentry; revisit if Phase 4 multi-env routing makes this noisy.
3. **Apple root cert is NOT checked in.** Repo `.gitignore` already blocks `*.cer`; download via new `make fetch-apple-root` target (curl + sha256 verify, see `app/storekit/certs/README.md`). The 90-day-runway test skips when the file is absent so dev machines without the cert don't fail; CI must run `make fetch-apple-root` during setup (Task 1.12 will wire that step).
4. **Chain verify is strict.** Each cert in `x5c` must be within validity, signed by the next entry, and the last entry must either equal the configured root (DER-byte compare) or be signed by it. EC-only — `JWSInvalid` if any issuer key isn't ECDSA. ES256 leaf check rejects non-P256 leaf keys before signature verification.
5. **Raw-r||s → DER signature re-encoding.** JWS ECDSA signatures are raw 64-byte `r || s` (RFC 7515 §3.4); `cryptography` only verifies DER. The verifier re-encodes via `encode_dss_signature(r, s)` before `verify` — covered by a tampered-signature test that flips one bit of `r`.
6. **Settings additions** in `app/config.py`: `app_bundle_id` (default `com.missinghue.hangs`, matches iOS `BUNDLE_ID_BASE` in `Configuration/Shared.xcconfig`), `storekit_environment` (`Sandbox`, override to `Production` per-deploy via Fly secret), `storekit_root_cert_path` (defaults to bundled location). No new env-var consumers yet — Task 1.9 wires the FastAPI dep.
7. **Test coverage:** 16 tests in `tests/storekit/test_verifier.py` — happy-path sandbox + prod, tampered payload, tampered signature, wrong bundle, wrong environment, unknown trust root, missing intermediate (broken chain), unsupported alg, malformed JWS string, signature with wrong key, `from_path` DER load, `from_path` missing-cert actionable error, ms-epoch `purchaseDate` parsing, missing required payload field, bundled-root validity runway (skipped without cert). `pytest tests/storekit -v`: 15 passed, 1 skipped, 0.04s.
8. **What 1.8 deliberately does NOT do.** No `from_settings` factory yet — keeps `Settings` import out of the verifier so Task 1.9 can wire the FastAPI dependency cleanly. No JWS verify cache yet (plan defers to 1.11). No subscription enforcement (C2 — non-consumable-only in Phase 1); `expiresDate` is parsed and raises `JWSExpired` if in the past, but Phase 1 product IDs never set it.

### Task 1.9 — `POST /v1/orders` + `GET /v1/orders/{id}`

- New router `apps/quiz-pack-api/app/api/v1/orders.py`.
- `POST /v1/orders`. Headers: `X-StoreKit-JWS: <jws>`. Body: `{transaction_id, product_id, prompt, language, target_count, category?, theme?}`.
- Flow:
  1. `AppleJWSVerifier.verify` → cross-check body's `transaction_id` and `product_id` match JWS payload. Mismatch → 400.
  2. Server-side product → tier mapping is authoritative: `pack_10|pack_20|pack_30|pack_50` → `target_count ∈ {10,20,30,50}`. Body's `target_count` is informational.
  3. Idempotency: `SELECT * FROM generation_orders WHERE transaction_id=?`. Hit → 200 with existing order_id. Miss → insert order + job, enqueue ARQ, return 202.
  4. Server guards: `10 <= len(prompt.strip()) <= 1000` (D2 free-form prompts need room for context; reject empties and trolling-length payloads); `language ∈ {en, sk, cs}` (matches existing app locales).
- `GET /v1/orders/{id}` returns the order + latest job snapshot.
- Auth: JWS itself is the auth in Phase 1. **No user token.** Phase 4 issues a server-side user token from first-seen JWS so library reads don't need a fresh JWS each time.

**Acceptance.** Curl with sandbox JWS → 202 + `order_id`; second curl with same JWS → 200 + same `order_id`; tampered body → 400; `GET /v1/orders/{id}` returns the row.

### Task 1.10 — ARQ worker scaffold + stub `process_order`

Worker is wired and exercises the SSE/pubsub plumbing. **No real generation yet** — Phase 2 swaps in `AdvancedQuestionGenerator`.

- `apps/quiz-pack-api/app/worker/`:
  - `worker.py` — `WorkerSettings` (redis_settings, `functions=[process_order]`, `max_jobs=2`, `max_tries=3`, `job_timeout=600`, `keep_result=86400`). The `max_tries` + `job_timeout` combo gives R5 a minimum mitigation in Phase 1: a stuck job is killed at 10min and retried up to 3× before being marked failed (full reconciler still ships in Phase 3).
  - `tasks.py` — `process_order(ctx, order_id)`:
    1. Walk through statuses `sourcing → generating → critiquing → verifying → scoring → persisting → done`, sleeping ~1s each.
    2. At each transition: `append_step` (returns `event_id`), update `progress`, publish `{event_id, step, progress}` to Redis pubsub `order:{order_id}:progress`.
    3. On `persisting`: insert `question_packs` (set `actual_count = N`, `generated_at = now()`), then N stub `questions` valid against the Pydantic model — e.g. `type='single_choice'`, `question='Stub question {i}'`, `possible_answers=['answer','wrong1','wrong2','wrong3']`, `correct_answer=['answer']`, `category=order.category or 'stub'`, `language=order.language`, all sharing the new `pack_id`. The shape must round-trip through `Question.from_dict` so the integration test in 1.12 doesn't trip on validation.
    4. On `done`: order.status = `delivered`, `pack_id` set, `delivered_at` stamped.
    5. Wrap in try/except: on failure → `status='failed'`, `error` populated, `refund_eligible=true` if `ctx['job_try'] >= max_tries` (use ARQ's built-in retry counter, but mirror the final value into `generation_jobs.retry_count` for observability).
- Phase 2 replaces only the body of `process_order`. The pubsub/step_log plumbing established here is the contract for all later phases.

**Acceptance.** After enqueue, order reaches `delivered` within ~10s; pack has N stub questions tagged with `pack_id`; `redis-cli SUBSCRIBE 'order:*:progress'` shows the events.

### Task 1.11 — SSE stream with Redis pubsub + step_log replay

- `GET /v1/orders/{id}/stream` using `sse-starlette`'s `EventSourceResponse`.
- Authz: `X-StoreKit-JWS` header for the matching `transaction_id`. (Subscription auth → Phase 4.)
- **JWS verify cache.** ECDSA P-256 verification on every reconnect adds up on flaky mobile networks. Cache `transaction_id → verified_at` in Redis with 60s TTL (key `jws:verified:{transaction_id}`). Cache hit → skip the chain verify and just confirm the JWS' `transaction_id` claim still matches the URL param. Cache miss → full verify + populate. Same pattern is reusable in `POST /v1/orders` and in Phase 4 session-token issuance.
- On connect:
  1. Read `Last-Event-ID` header (default 0).
  2. Replay all `step_log` entries with `event_id > last_event_id` in order — catches up reconnecting clients.
  3. Subscribe to Redis pubsub `order:{order_id}:progress`. Forward each message as an SSE event with `id=event_id`.
  4. On step `done` or `failed`: emit final event and close.
- Heartbeat: SSE comment line every 15s to survive mobile NAT timeouts.
- `X-Accel-Buffering: no` header to disable proxy buffering.

**Acceptance.** `curl -N -H "X-StoreKit-JWS: ..." /v1/orders/{id}/stream` after enqueue receives ~7 events ending with `event: done`. Disconnect mid-stream and reconnect with `Last-Event-ID: 3` resumes at event 4 with no duplicates.

### Task 1.12 — End-to-end smoke test (CI)

- `tests/integration/test_order_e2e.py`:
  - Boots app + ARQ worker (subprocesses or in-process via `asgi-lifespan` + ARQ test runner — pick whichever proves stable).
  - Mints sandbox JWS via fixture signed with a test cert in `tests/fixtures/storekit/`.
  - POST `/v1/orders` → poll `/v1/orders/{id}` until `status=delivered` (timeout 30s) → assert `actual_count == target_count` stub questions exist with the order's `pack_id`.
  - Connect to SSE stream, assert ≥ 5 events including a `done`.
  - **Cost guardrail**: assert `total_cost_cents == 0` on the delivered job — Phase 1 stub pipeline must not call any paid LLM. Phase 2 PRs that introduce real generation will need to bump this assertion explicitly, which makes accidental cost-leak regressions visible in PR review.
  - **Resume coverage**: reconnect SSE with `Last-Event-ID: 3` mid-stream and assert resume from event 4 with no duplicates (covers 1.11 acceptance in CI, not just manual curl).
- CI: extend `backend-ci` job (per memory `reference_ci_cd`) to start GitHub Actions services `pgvector/pgvector:pg16` + `redis:7`, run this test. Path filter on `apps/quiz-pack-api/**` and `packages/shared/**`.

**Acceptance.** Test passes locally and in CI on PRs touching the relevant paths.

---

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| R1 | pgvector recall worse than ChromaDB at scale | After 1.7 run `EXPLAIN ANALYZE` on a 1000-question sample with the same query as voice quiz. If recall drops, raise `lists` (ivfflat) or switch to HNSW (`pgvector >= 0.5`). |
| R2 | Migration scripts (1.6/1.7) run partially → mixed state | Each row insert in its own transaction; idempotent on `questions.id`; re-runnable. |
| R3 | Apple rotates root cert chain | Bundled cert is checked into repo; rotation cycle is yearly+. CI assertion fails ≥ 90 days before expiry. |
| R4 | Fly proxy buffers SSE | `X-Accel-Buffering: no` + `sse-starlette`. Fallback: client polls `GET /v1/orders/{id}` at 1Hz. |
| R5 | ARQ worker dies mid-job → order stuck `in_progress` | Phase 1 minimum: ARQ `max_tries=3` + `job_timeout=600` (10min) in 1.10 — stuck job is killed and retried up to 3×. Full reconciler cron + automatic refund flagging ships in Phase 3. Document the 10min worst-case latency in the runbook. |
| R6 | Two `pending.db` files diverge during 1.6 | Freeze `/import` writes (≤ 5 min) per runbook in 1.6 docstring. |
| R7 | pgvector unavailable on default Fly Postgres image; ivfflat index build memory pressure during 1.7 | Provisioned `quiz-pack-db` at 1 GB RAM (256 MB OOMs `apt-get install postgresql-17-pgvector`). Custom image `registry.fly.io/quiz-pack-db:pgvector-0.8.2` baked from [`infra/quiz-pack-db/`](../../infra/quiz-pack-db/) — runtime apt install does not persist across machine restarts. Migration script in 1.7 still does `SET maintenance_work_mem = '128MB';` as belt-and-braces. |
| R8 | Alembic downgrade fails on `vector(...)` columns + dropped CHECK constraints | Treat all 1.5 migrations as **forward-only**. Document policy in alembic `env.py` header. Recovery from a bad migration = restore from Fly Postgres snapshot, not `alembic downgrade`. |
| R9 | Concurrent writers race on `step_log` JSONB append → events lost | 1.5 forces single-statement `UPDATE ... step_log = step_log \|\| $1` with `event_id` derived inside the same statement. Code review checklist item: any future JSONB array column must follow the same pattern. |

---

## Definition of done

1. `quiz-pack-api` deployed to Fly with `web` + `worker` process groups, both healthy.
2. Postgres has all four tables; pgvector extension enabled.
3. ChromaDB content + `pending.db` content migrated into Postgres; ChromaDB still readable but no longer the write path.
4. End-to-end curl from a sandbox StoreKit JWS → SSE stream → delivered pack with stub questions, ≤ 30s.
5. `tests/integration/test_order_e2e.py` green in CI.
6. `apps/question-generator/` no longer exists; CLAUDE.md updated.
7. INDEX.md row + TODO line `[ ] #33` flipped to `[x]`; #32 `Triage` flipped to `enhancement · done` (umbrella role only).
8. **Structured logging** wired via `structlog`: `order.created`, `order.delivered`, `order.failed`, `job.step_started`, `job.step_finished` events emit JSON with `order_id`, `job_id`, `step`, `event_id`, `total_cost_cents`. Sentry hookup ships in Phase 5, but stable event names + fields from Phase 1 mean Phase 2 doesn't need a logging rewrite.
9. `apps/quiz-pack-api/README.md` documents: local stack boot (`make dev` or equivalent), prod migration runbooks for 1.6 and 1.7, the **forward-only migration policy** (R8), and the 10min worst-case order-stuck latency (R5).

---

## Out-of-scope traceability (target phase issue numbers)

- **#34 Phase 2** — `PackGenerator` orchestrator + delete duplicate generators (#32 F1, F2).
- **#35 Phase 3** — Moderation, fact-pool cache (revised D5 → C3), per-tier cost cap, prompt caching, stuck-job reconciler.
- **#36 Phase 4** — iOS app integration, **subscription tier (revised D1 → C2)**, ASSN V2 webhook, entitlement state machine.
- **#37 Phase 5** — Langfuse, DeepEval, Sentry on quiz-pack-api.
- **#38 Phase 6** — Drop ChromaDB volume + JSON-on-disk artifacts, admin UI behind `/admin`.

---

## Pointers

- `Question` Pydantic — `packages/shared/quiz_shared/models/question.py:9`.
- Existing storage layer (PendingStore + ChromaDB split per #22/#27) — `packages/shared/quiz_shared/database/{pending_store,chroma_client,question_store,sql_client}.py`.
- Existing FastAPI routes — `apps/question-generator/app/api/routes.py`.
- Reference Dockerfile + fly.toml shape — `apps/quiz-agent/{Dockerfile,fly.toml}`.
- Custom Postgres image source — `infra/quiz-pack-db/` (Task 1.1).
- Constraining memory notes: `project_dockerfile_drift`, `feedback_qgen_import_cwd`, `feedback_company_accounts`, `feedback_secrets_management`, `feedback_backend_auto_deploy`, `project_prod_chroma_mount`.
