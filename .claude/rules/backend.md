---
paths: ["apps/quiz-agent/**", "apps/quiz-pack-api/**", "packages/shared/**"]
---

# Backend Development Rules

## Architecture

### Session Management
- In-memory with TTL, write-through to SQLite so active sessions survive a restart (`app/session/manager.py`)
- UUID4 session IDs; accounts via Sign in with Apple + App Attest (`app/auth/`)

### AI Integration
- **Transcription:** OpenAI `gpt-transcribe` only (`stt_model`; #208 removed Scribe from the answer path) — `app/voice/`
- **Evaluation:** `EVAL_MODEL`, default Claude Haiku 5.5 (`app/evaluation/evaluator.py`)
- **TTS:** ElevenLabs primary, OpenAI TTS as live fallback — `app/tts/providers.py`
- **RAG:** Postgres + pgvector for semantic question retrieval (voice-quiz read path cut over 2026-05-28, #36 task 2.20)

### LLM client factory — never instantiate SDK clients directly (issue #53)
All LLM calls go through `quiz_shared.llm.factory`. Call sites ask it for a client (and, where the model is configurable, `resolve_model(id)`); they **never** read an API key or hardcode a `base_url`. One env var routes the whole pipeline:
- `LLM_GATEWAY=direct` (default) — canonical provider endpoints, today's behavior. This is the rollback lever.
- `LLM_GATEWAY=openrouter` — chat + embeddings + Gemini verification + Claude scoring all route through OpenRouter on one key/balance.
- `LLM_GATEWAY=session` — **dev-only (#169 — session gateway)**: every chat role runs on the Claude Code subscription via `claude -p` (`session:<fable|opus|sonnet|haiku>` ids, `quiz_shared/llm/session_cli.py`); non-Claude ids map to a Claude tier by class (table in `factory.session_model_for`, override `LLM_SESSION_MAP`). Embeddings/audio/image stay on OpenAI. Transport only — prompts, parsers, guards and feature flags are unchanged, so the API pipeline remains the source of truth. Never set on Fly. Requires `claude auth status` = claude.ai login, or `oauth_token` + `firstParty` (cloud sessions); API-key auth is refused.
- `LLM_GATEWAY=mixed` — **offline runs on the Anthropic API credit**: behaves as `openrouter` (non-Claude models, embeddings, judges via OpenRouter) but Claude ids must go to the Anthropic API; fails loud at the first call if `ANTHROPIC_API_KEY` or `OPENROUTER_API_KEY` is missing. Not for Fly.

- **Claude ids (#196 — AI calls to the direct Anthropic API):** any `claude-*` / `anthropic/claude-…` chat id goes straight to the Anthropic API (`ChatAnthropic`; `quiz_shared/llm/anthropic_route.py`) whenever `ANTHROPIC_API_KEY` is set and the gateway isn't `session` — under either gateway. No key → the gateway route above. `bedrock:`/`session:` ids keep their routes.

Use `factory.openai_client(async_=…)` (native OpenAI SDK) or `factory.chat_openai(model, …)` (LangChain). **Audio (TTS/Whisper) and image (gpt-image-1) pass `direct=True`** — OpenRouter does not serve them, so they stay on canonical OpenAI under either gateway. When adding a new model, add its OpenRouter slug to `_REMAP_OPENROUTER` in the factory, not at the call site.

Direct-mode degradation: without `GOOGLE_API_KEY`, Gemini verification falls back to heuristic; without `ANTHROPIC_API_KEY`, the second scorer drops. `openrouter` mode needs neither.

### Use the model only for judgment calls
When writing app code that calls an LLM (question generation, evaluation, scoring): use the model for classification, drafting, summarization, extraction.
Do NOT use it for routing, retries, status-code handling, deterministic transforms.

### Database
- **Postgres + pgvector:** Canonical store for question embeddings + metadata. Voice quiz (`apps/quiz-agent`) reads via `PgvectorQuestionStore` (see `packages/shared/quiz_shared/database/pgvector_client.py`). quiz-pack-api writes via `PersistStage`.
- **ChromaDB:** RETIRED (#41 Phase A, 2026-07-07) — client + dep deleted repo-wide. Prod `/data/chroma` wipe + `CHROMA_PATH` secret unset are the founder-gated #41 Phase B tail. Never reintroduce a ChromaDB path.
- **SQLite:** Ratings and persistent data.

## API Design

- **Timestamps:** ISO 8601 with timezone (required for mobile)
- **Audio endpoints:** Accept multipart/form-data, MP3/M4A, max 10MB
- **CORS:** Allow all origins in development
- **OpenAPI spec** at `/docs` — the contract the hand-written iOS Codable structs must match (`/verify-api`)

## Shared Package

All services import from `packages/shared`:
- `quiz_shared.models.session` — QuizSession, Participant
- `quiz_shared.models.question` — Question
- `quiz_shared.models.participant` — Participant

When updating shared models, verify iOS still builds (`/verify-api`).

## Mobile Client Compatibility

- Audio: Opus codec, responses under 50MB
- Timeouts: 30s default, implement pagination for lists (future)
- Include session state in responses (iOS needs to know if expired)

## Deployment

Production runs on the Hetzner server since 2026-11-06 (#222 — moving the backend to Hetzner, `infra/hetzner/README.md`). Normal path: the **Backend Deploy** workflow (`.github/workflows/backend-deploy.yml`, #207): full Backend CI → `infra/hetzner/deploy-ssh.sh` over SSH (build, migrate, swap, wait healthy, automatic rollback without migrating) → smoke on `api.trubbo.app` / `pack.trubbo.app`; `deployed/<app>` tags mark what prod runs. Run it with `gh workflow run backend-deploy.yml --ref main` (Hetzner has no staging, so a branch ref only runs the tests). The `/deploy` skill is the manual emergency path. Backend CI's `Backend CI gate` job is a required PR check.

**Never `fly deploy` the app configs** (`apps/*/fly.toml`) or a release image to `quiz-agent-api` / `quiz-pack-api`: those Fly apps now run only the forwarder for builds that call `*.fly.dev`, and a deploy replaces it with the old app on the old Fly database. The image notes in `docs/runbooks/fly-deploy.md` (dependency lock, unprivileged user) still apply to the Dockerfiles; its Fly deploy commands do not.

## Migrations

- Migrations only add (expand). Drops/renames ship one release later (contract), after no running code reads the old column/table.
- The `questions` table is owned by quiz-pack-api but read by quiz-agent (`apps/quiz-agent/alembic/env.py`). Any change to it needs the matching quiz-agent change deployed first.
- `deploy-ssh.sh` runs `alembic upgrade head` for each touched app before the swap (on Fly this was the `release_command`).
- Never downgrade the prod DB. Roll back by running the previous code without migrating (see `/deploy` skill, Rollback; the older alembic would fail on the unknown revision); the boot check `apps/quiz-pack-api/app/db/migration_check.py` accepts a DB ahead of code.
