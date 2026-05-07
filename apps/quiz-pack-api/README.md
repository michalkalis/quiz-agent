# Question Generator API

Admin tool for generating and curating quiz questions with RAG-based duplicate detection.

## Features

- ✅ LLM-powered question generation (batches of 1-50)
- ✅ Enhanced prompt template with quality examples
- ✅ RAG-based duplicate detection (cosine similarity > 0.85)
- ✅ Semantic search for existing questions
- ✅ Import from ChatGPT JSON output
- ✅ FastAPI REST endpoints
- ✅ Multi-type support (text, text_multichoice)

## Quick Start

### Install Dependencies

```bash
# From project root
cd apps/question-generator
uv pip install -e .
```

### Set Environment Variables

```bash
export OPENAI_API_KEY=your_key_here
```

### Run Server

```bash
# From apps/question-generator
python -m uvicorn app.main:app --reload --port 8001
```

Or:

```bash
python app/main.py
```

API will be available at: `http://localhost:8001`

Interactive docs at: `http://localhost:8001/docs`

## API Endpoints

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
question-generator/
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
└── README.md
```

## Next Steps

- Add Gradio UI for visual review workflow
- Implement pending review storage
- Add analytics dashboard
- Batch operations for large datasets

---

## quiz-pack-api Phase 1 — local stack + cloud provisioning (issue #33)

This service is being migrated from `apps/question-generator/` → `apps/quiz-pack-api/`
(Task 1.2). All files in this section already live at their post-rename paths via
`git mv`, so the docker-compose / Makefile / init script will move along.

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

### Cloud provisioning (Phase 1, Task 1.1)

These steps run **once** by the human operator. The Fly secrets land on the new
`quiz-pack-api` app, which is created in **Task 1.2** — postpone the
`fly secrets set ... -a quiz-pack-api` calls until after that rename + deploy.

**1. Fly Postgres (`quiz-pack-db`)**

```bash
# Region cdg, smallest paid tier. Per memory feedback_company_accounts: use the
# company Fly org. Save the connection string Fly prints — that's $DATABASE_URL.
fly postgres create \
  --name quiz-pack-db \
  --region cdg \
  --vm-size shared-cpu-1x \
  --volume-size 1 \
  --initial-cluster-size 1 \
  --org <company-org>

# Enable pgvector inside the application database (NOT the postgres superuser db).
fly postgres connect -a quiz-pack-db -d quiz_pack_db <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SELECT extname FROM pg_extension WHERE extname='vector';
SQL
```

**256 MB caveat (Risk R7).** The 256 MB `shared-cpu-1x` tier has
`maintenance_work_mem=64MB` by default, which OOMs the ivfflat index build
during Task 1.7 (~10 k+ vectors at dim 1536). The Task 1.7 migration script
runs `SET maintenance_work_mem = '128MB';` in its own session before
`CREATE INDEX ... USING ivfflat`. If the build still struggles, scale the DB
to 512 MB for the migration window:

```bash
fly machine update <machine-id> --vm-memory 512 -a quiz-pack-db
# ... run migration ...
fly machine update <machine-id> --vm-memory 256 -a quiz-pack-db
```

**2. Upstash Redis** (per memory `feedback_company_accounts`: company account)

Create a free-tier global Redis database in the company Upstash account, region
closest to `cdg` (e.g. `eu-west-1`). Copy the **TLS** connection string
(`rediss://default:<token>@<host>:<port>`) — that's `$REDIS_URL`.

**3. Fly secrets** (defer to Task 1.2 once the `quiz-pack-api` app exists)

```bash
fly secrets set \
  DATABASE_URL='postgres://quiz_pack:...@quiz-pack-db.flycast:5432/quiz_pack_db' \
  REDIS_URL='rediss://default:...@...upstash.io:6379' \
  -a quiz-pack-api
```

Local dev keeps these in `.env` (gitignored), per memory
`feedback_secrets_management`.

### Acceptance (Task 1.1)

- `psql $DATABASE_URL -c "SELECT extname FROM pg_extension WHERE extname='vector';"` → 1 row (local & prod).
- `redis-cli -u $REDIS_URL ping` → `PONG` (local & prod).
- `make dev` boots the full local stack and `curl localhost:8003/health` returns 200.
