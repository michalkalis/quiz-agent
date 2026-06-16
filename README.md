# Quiz Agent — Monorepo

Voice-first AI quiz platform for hands-free trivia while driving.

## Layout

| Path | What |
|------|------|
| `apps/quiz-agent` | FastAPI backend (quiz session engine, :8002) |
| `apps/quiz-pack-api` | Quiz-pack order/generation service (:8003, issue #33) |
| `apps/web-ui` | Web UI |
| `apps/ios-app` | SwiftUI iOS app (`Hangs`) |
| `packages/shared` | Shared Pydantic models / utilities |
| `infra/` | Standalone infra (e.g. quiz-pack DB) |
| `design/` | Live Pencil design source (`quiz-agent.pen`) |
| `docs/` | Issues, PRDs, runbooks, research, handoffs, archive |

## Where to start

- **`CLAUDE.md`** — working agreement, behavioral rules, quick-reference commands.
- **`CONTEXT.md`** — domain glossary (read before PRDs / issues / architecture work).
- **`docs/todo/TODO.md`** — task index · **`docs/issues/INDEX.md`** — issue index.

## Quick start

```bash
# Install
uv pip install -e apps/quiz-agent && uv pip install -e packages/shared

# Backend (:8002)
cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002

# Tests
cd apps/quiz-agent && pytest tests/ -v
```

Deploy and stack-specific commands live in `docs/runbooks/` and `.claude/rules/`.
