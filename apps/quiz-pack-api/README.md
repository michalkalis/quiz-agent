# quiz-pack-api

On-demand quiz pack generation API. Verifies StoreKit JWS, enqueues an ARQ
job per order, runs sourcing → generating → critiquing → verifying → scoring →
persisting, and streams progress to the iOS client over SSE. Strategy lives in
`docs/issues/issue-32-on-demand-generation-service.md`; Phase 1 (this codebase
shape) is tracked in `docs/issues/issue-33-quiz-pack-api-phase-1.md`.

This directory was renamed from `apps/question-generator/` in issue #33 Task
1.2. The legacy admin endpoints (`/api/v1/generate`, `/api/v1/import`,
`/api/v1/questions/*`) are retained until Phase 6 cleanup.

## Quick Start

### Install Dependencies

```bash
# From project root
cd apps/quiz-pack-api
uv pip install -e .
```

### Set Environment Variables

```bash
export OPENAI_API_KEY=your_key_here
```

### Run Server

```bash
# From apps/quiz-pack-api
python -m uvicorn app.main:app --reload --port 8003
```

API will be available at: `http://localhost:8003`

Interactive docs at: `http://localhost:8003/docs`

## Legacy admin endpoints (pre-issue-33)

### Generate Questions

```bash
POST /api/v1/generate
{
  "count": 10,
  "difficulty": "medium",
  "topics": ["science", "history"],
  "categories": ["adults"],
  "type": "text"
}
```

### Import Questions (from ChatGPT)

```bash
POST /api/v1/import
{
  "questions": [
    {
      "question": "What is...",
      "correct_answer": "...",
      "topic": "Science",
      "difficulty": "medium",
      "category": "adults"
    }
  ],
  "source": "chatgpt"
}
```

### Check Duplicates

```bash
POST /api/v1/questions/duplicates?question_text=What is the capital of France?&threshold=0.85
```

### Approve Questions

```bash
POST /api/v1/questions/approve
{
  "question_ids": ["temp_abc123"],
  "force": false
}
```

### Search Questions

```bash
GET /api/v1/questions/search?query=space questions&difficulty=medium&limit=10
```

### Export Prompt for ChatGPT

```bash
GET /api/v1/export/chatgpt?count=10&difficulty=medium&topics=science
```

## Manual ChatGPT Workflow

1. Get prompt: `GET /api/v1/export/chatgpt`
2. Copy prompt to ChatGPT
3. Generate questions in ChatGPT
4. Copy JSON output
5. Import: `POST /api/v1/import`
6. Review and approve: `POST /api/v1/questions/approve`

## Architecture

```
quiz-pack-api/
├── app/
│   ├── main.py              # FastAPI application
│   ├── generation/
│   │   ├── generator.py     # LLM question generation
│   │   ├── prompt_builder.py # Dynamic prompt construction
│   │   ├── storage.py       # ChromaDB integration
│   │   └── examples.py      # Quality examples
│   └── api/
│       ├── routes.py        # API endpoints
│       └── schemas.py       # Request/response models
├── prompts/
│   └── question_generation.md  # Enhanced prompt template
├── docker-compose.yml       # Local Postgres+pgvector + Redis (issue #33)
├── Makefile                 # `make dev` boots the stack
└── README.md
```

---

## Phase 1 — local stack + cloud provisioning (issue #33)

### Local stack

```bash
make dev-db        # boots Postgres (pgvector) + Redis
make dev           # dev-db + uvicorn on :8003 (ARQ worker added in Task 1.10)
make dev-down      # stops containers, keeps volumes
make dev-reset     # ⚠️  drops volumes (destroys local data)
make dev-psql      # psql shell into local quiz_pack DB
make dev-redis-cli # redis-cli into local Redis
```

The compose stack mounts `db/init/01-vector.sql`, which runs `CREATE EXTENSION
vector;` on first boot. Verify:

```bash
psql "postgresql://quiz:quiz@localhost:5432/quiz_pack" \
  -c "SELECT extname FROM pg_extension WHERE extname='vector';"
# → 1 row

redis-cli -u "redis://localhost:6379/0" ping
# → PONG

curl -fsS http://localhost:8003/health
# → {"status":"healthy"}
```

`.env` (gitignored) should contain `DATABASE_URL`, `TEST_DATABASE_URL`, and
`REDIS_URL` — see the project-root `.env.example` for the canonical values.

### Cloud provisioning (Task 1.1, completed 2026-05-07)

The Fly Postgres app `quiz-pack-db` is provisioned in region `cdg`, sized at
**1 GB RAM** (the 256 MB tier OOMs `apt-get install`). It runs a custom image
`registry.fly.io/quiz-pack-db:pgvector-0.8.2` that bakes the
`postgresql-17-pgvector` apt package into `flyio/postgres-flex:17.2`. The
default Fly Postgres image lacks pgvector, and runtime `apt install` doesn't
persist across machine restarts (immutable container, overlay fs is wiped).

The image Dockerfile + rebuild runbook lives at
[`infra/quiz-pack-db/`](../../infra/quiz-pack-db/).

`pgvector` v0.8.2 is created in the `quiz_pack` database on prod (matching the
local DB name). The Fly secrets `DATABASE_URL` and `REDIS_URL` are set on the
`quiz-pack-api` Fly app once it exists (Task 1.2 below).

```bash
# One-time: enable pgvector in the prod quiz_pack DB
fly ssh console -a quiz-pack-db -C 'bash -lc "PGPASSWORD=$OPERATOR_PASSWORD createdb -h localhost -U postgres quiz_pack && psql -h localhost -U postgres -d quiz_pack -c \"CREATE EXTENSION vector;\""'
```

### Cloud provisioning — Upstash Redis (Task 1.1)

Create a free-tier global Redis database in Upstash, region closest to `cdg`
(e.g. `eu-west-1`). Copy the **TLS** connection string
(`rediss://default:<token>@<host>:<port>`) — that's `$REDIS_URL`.

### Cloud provisioning — Fly secrets (Task 1.2)

Run **after** `fly deploy -c apps/quiz-pack-api/fly.toml` has created the app:

```bash
fly secrets set \
  DATABASE_URL='postgres://postgres:<password>@quiz-pack-db.flycast:5432/quiz_pack' \
  REDIS_URL='rediss://default:<token>@<host>.upstash.io:6379' \
  -a quiz-pack-api
fly deploy -c apps/quiz-pack-api/fly.toml   # restart so app picks up secrets
```

Local dev keeps these in `.env` (gitignored), per memory
`feedback_secrets_management`.

### Acceptance (Task 1.1)

- `psql $DATABASE_URL -c "SELECT extname FROM pg_extension WHERE extname='vector';"` → 1 row (local & prod). ✓
- `redis-cli -u $REDIS_URL ping` → `PONG` (local & prod). ✓
- `make dev` boots the full local stack and `curl localhost:8003/health` returns 200. ✓
