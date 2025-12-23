---
paths: apps/quiz-agent/**, apps/question-generator/**, packages/shared/**
---

# Backend Development Rules

## Python/FastAPI Standards

- **Python Version:** 3.11+ with uv for dependency management
- **Async/Await:** Use async/await for all I/O operations (database, file access, API calls)
- **Type Hints:** Always include type hints for function parameters and return values
- **Validation:** Use Pydantic models for request/response validation
- **Error Handling:** Raise HTTPException with detailed error messages and appropriate status codes

## Key Architecture Patterns

### Session Management
- **Storage:** In-memory with TTL (not persistent to database)
- **TTL:** Sessions expire after inactivity period
- **Session ID:** UUID4 format, stored in dictionary
- **No Authentication:** MVP phase, no user auth required

### AI Integration
- **Transcription:** OpenAI Whisper API (via audio file upload)
- **Evaluation:** GPT-4 for answer correctness and feedback
- **TTS:** OpenAI TTS API (returns Opus audio format)
- **RAG:** ChromaDB for semantic question retrieval

### Database
- **ChromaDB:** Shared instance for question embeddings across all services
- **SQLite:** For ratings and persistent data (questions)
- **Migrations:** None yet (file-based DB)

## API Design Guidelines

### Response Format
- **Timestamps:** ISO 8601 with timezone (required for mobile clients)
- **Error Responses:** Consistent structure with `detail` field
- **Audio Endpoints:** Accept multipart/form-data for file uploads
- **CORS:** Allow all origins in development (localhost:*)

### OpenAPI Specification
- **Auto-Generation:** FastAPI generates OpenAPI spec automatically at `/docs`
- **Critical:** This spec is consumed by iOS Swift OpenAPI Generator
- **Model Changes:** When updating Pydantic models, verify iOS Codable structs still match
- **Documentation:** Keep endpoint descriptions clear for auto-generated clients

## Shared Package Dependencies

### packages/shared/
All backend services import from `packages/shared`:
- `quiz_shared.models.session` - QuizSession, Participant models
- `quiz_shared.models.question` - Question model
- `quiz_shared.models.participant` - Participant model

**Important:** When updating shared models:
1. Update the Pydantic model in `packages/shared/`
2. Verify iOS app still builds (models must match Codable structs)
3. Update API documentation if response structure changed

## Common Development Commands

### Start Backend API
```bash
cd apps/quiz-agent
uvicorn app.main:app --reload --port 8002
```

### Start Question Generator
```bash
cd apps/question-generator
uvicorn app.main:app --reload --port 8003
```

### Run Tests
```bash
cd apps/quiz-agent
pytest tests/ -v
```

### Lint and Format
```bash
# From root directory
ruff check apps/quiz-agent/
ruff format apps/quiz-agent/
```

### Install Dependencies
```bash
# Install in editable mode
uv pip install -e apps/quiz-agent
uv pip install -e apps/question-generator
uv pip install -e packages/shared
```

### Generate OpenAPI Spec (for iOS client)
```bash
# OpenAPI spec available at:
# http://localhost:8002/openapi.json
curl http://localhost:8002/openapi.json > apps/ios-app/openapi.yaml
```

## Environment Variables

Required in `.env` or environment:
```
OPENAI_API_KEY=sk-...
```

Optional:
```
ENVIRONMENT=development|production
PORT=8002
HOST=0.0.0.0
```

## Production Deployment

- **Platform:** Fly.io
- **URL:** https://quiz-agent-api.fly.dev
- **Volumes:** 3GB persistent storage for ChromaDB
- **Cost:** ~$110/mo at 100 daily users

### Deploy Command
```bash
fly deploy
```

## Error Handling Best Practices

### Custom Exceptions
```python
from fastapi import HTTPException

# Good: Specific status codes and messages
raise HTTPException(
    status_code=404,
    detail="Session not found"
)

# Bad: Generic errors
raise Exception("Something went wrong")
```

### Logging
- Use structured logging with context
- Include session_id for traceability
- Log errors before raising HTTPException

## Testing Guidelines

- **Unit Tests:** Test business logic in isolation
- **Integration Tests:** Test API endpoints with TestClient
- **Mock External Services:** Don't call OpenAI API in tests
- **Test Data:** Use fixtures for common test data

## Security Considerations

- **Input Validation:** All user input validated via Pydantic
- **File Upload:** Validate audio file format and size
- **Rate Limiting:** TODO (not implemented yet)
- **API Keys:** Never commit to git, use environment variables
- **CORS:** Restrict in production (currently allows all for development)

## Mobile Client Compatibility

### Audio Endpoints
- Accept multipart/form-data (FormData from iOS)
- Support MP3 and M4A formats
- Maximum file size: 10MB (configurable)

### Response Sizes
- Keep responses under 50MB for reliable mobile networks
- Audio files: Use Opus codec for compression
- Implement pagination for list endpoints (future)

### Network Resilience
- Implement timeouts (30 seconds default)
- Return meaningful error messages for client retry logic
- Include session state in responses (iOS needs to know if session expired)
