---
paths: apps/quiz-agent/**, apps/question-generator/**, packages/shared/**
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
- **RAG:** ChromaDB for semantic question retrieval

### Database
- **ChromaDB:** Shared instance for question embeddings
- **SQLite:** Ratings and persistent data

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
