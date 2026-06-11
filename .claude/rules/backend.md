---
paths: ["apps/quiz-agent/**", "apps/quiz-pack-api/**", "packages/shared/**"]
---

# Backend Development Rules

## Architecture

### Session Management
- In-memory with TTL (not persistent)
- UUID4 session IDs, no authentication (MVP)

### AI Integration
- **Transcription:** OpenAI Whisper (audio file upload)
- **Evaluation:** GPT-4 for answer correctness + feedback
- **TTS:** OpenAI TTS API (Opus format)
- **RAG:** Postgres + pgvector for semantic question retrieval (voice-quiz read path cut over 2026-05-28, #36 task 2.20)

### LLM client factory — never instantiate SDK clients directly (issue #53)
All LLM calls go through `quiz_shared.llm.factory`. Call sites ask it for a client (and, where the model is configurable, `resolve_model(id)`); they **never** read an API key or hardcode a `base_url`. One env var routes the whole pipeline:
- `LLM_GATEWAY=direct` (default) — canonical provider endpoints, today's behavior. This is the rollback lever.
- `LLM_GATEWAY=openrouter` — chat + embeddings + Gemini verification + Claude scoring all route through OpenRouter on one key/balance.

Use `factory.openai_client(async_=…)` (native OpenAI SDK) or `factory.chat_openai(model, …)` (LangChain). **Audio (TTS/Whisper) and image (gpt-image-1) pass `direct=True`** — OpenRouter does not serve them, so they stay on canonical OpenAI under either gateway. When adding a new model, add its OpenRouter slug to `_REMAP_OPENROUTER` in the factory, not at the call site.

Direct-mode degradation: without `GOOGLE_API_KEY`, Gemini verification falls back to heuristic; without `ANTHROPIC_API_KEY`, the second scorer drops. `openrouter` mode needs neither.

### Use the model only for judgment calls
When writing app code that calls an LLM (question generation, evaluation, scoring): use the model for classification, drafting, summarization, extraction.
Do NOT use it for routing, retries, status-code handling, deterministic transforms.

### Database
- **Postgres + pgvector:** Canonical store for question embeddings + metadata. Voice quiz (`apps/quiz-agent`) reads via `PgvectorQuestionStore` (see `packages/shared/quiz_shared/database/pgvector_client.py`). quiz-pack-api writes via `PersistStage`.
- **ChromaDB:** Read-only legacy store until Phase 6 (#41) retires it. No code path writes to ChromaDB after 2026-05-28; the Fly volume stays mounted but is frozen. Do not add new ChromaDB writers.
- **SQLite:** Ratings and persistent data.

## Local Dev

| Service | Start command |
|---------|---------------|
| quiz-agent (`:8002`) | `cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002` |
| quiz-pack-api (`:8003`) | `cd apps/quiz-pack-api && uvicorn app.main:app --reload --port 8003` |

## API Design

- **Timestamps:** ISO 8601 with timezone (required for mobile)
- **Audio endpoints:** Accept multipart/form-data, MP3/M4A, max 10MB
- **CORS:** Allow all origins in development
- **OpenAPI spec** at `/docs` — consumed by iOS Swift OpenAPI Generator

## Shared Package

All services import from `packages/shared`:
- `quiz_shared.models.session` — QuizSession, Participant
- `quiz_shared.models.question` — Question
- `quiz_shared.models.participant` — Participant

When updating shared models, verify iOS still builds (`/verify-api`).

## Lint/Format

```bash
ruff check apps/quiz-agent/
ruff format apps/quiz-agent/
```

## Mobile Client Compatibility

- Audio: Opus codec, responses under 50MB
- Timeouts: 30s default, implement pagination for lists (future)
- Include session state in responses (iOS needs to know if expired)

## Deployment

Known Fly.io pitfalls (Dockerfile dep drift, CHROMA_PATH/mount mismatch): see `docs/runbooks/fly-deploy.md`. Read it before `fly deploy` or before changing `[[mounts]]` in `fly.toml`.
