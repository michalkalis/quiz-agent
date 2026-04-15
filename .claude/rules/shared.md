# Shared Development Standards

## Git Workflow

Solo project — commit directly to main. No feature branches or PRs needed.

### Commit Messages
Follow Conventional Commits: `<type>(<scope>): <subject>`

**Types:** feat, fix, docs, style, refactor, test, chore
**Scopes:** ios, backend, questions, web, shared, ci

## API Contract

**OpenAPI as source of truth.** FastAPI generates the spec; iOS Codable structs must match backend Pydantic models.

When changing API models:
1. Update Pydantic model in `packages/shared/` or `apps/quiz-agent/`
2. Verify OpenAPI spec: `curl http://localhost:8002/openapi.json`
3. Update iOS Codable structs to match
4. Run `/verify-api` to confirm sync

## Testing

- **Backend:** `pytest tests/ -v` — mock OpenAI calls, use fixtures
- **iOS:** Unit test ViewModels with mocked services
- Test commands in CLAUDE.md quick reference table
