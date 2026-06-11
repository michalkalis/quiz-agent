# Shared Development Standards

## Git Workflow

Solo project — commit directly to main. No feature branches or PRs needed.

### Commit Messages
Follow Conventional Commits: `<type>(<scope>): <subject>`

**Types:** feat, fix, docs, style, refactor, test, chore
**Scopes:** ios, backend, questions, web, shared, ci

## Referring to Issues & Tasks

A number is an identifier, never a label. Never write a bare `#45` or `42.20` in prose, commits, or docs — always pair it with its short human title so it reads on its own:

- ✅ `#45 — iOS MCQ voice + redesign`, `task 42.20 (make MCQ patterns selectable)`
- ❌ `reclassified #45`, `42.20 unblocked`

The number stays as the stable anchor (file names, cross-refs, git); the title is what makes it legible to someone without the backlog open. Expand project shorthand on first use in a given doc/message.

### Project shorthand glossary

| Term | Meaning |
|------|---------|
| `#NN` | Issue number → `docs/issues/issue-NN-{slug}.md`; the slug is its human title |
| `NN.X` | Sub-task X within issue #NN (e.g. `42.20`) — name it when referenced |
| `RS-01`..`RS-NN` | iOS regression scenario (end-to-end sim test), see `/regression` |
| `Track A/B/…` | A parallel stream of work inside one issue |
| `Ralph` | Overnight autonomous agent loop (runs on `mba`) |
| `mba` | The agent Mac (`ssh mba`) that builds iOS + runs Ralph |
| `MCQ` | Multiple-choice question (vs. open/voice answer) |

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

## Config & Infrastructure

Prefer local and project-scoped config. Before recommending a cloud service or global config change, check whether existing local hardware or project-scoped config already covers the need.
Use `.claude/settings.local.json` for repo-specific settings, not `~/.claude/settings.json`.
Ground every infrastructure plan in the actual current state of existing machines and config.
