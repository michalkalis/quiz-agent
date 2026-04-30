# Quiz Agent - Monorepo

AI-powered quiz platform with voice-based interaction. Designed for hands-free trivia while driving.

## Repository Structure

```
quiz-agent/
├── apps/
│   ├── quiz-agent/          # FastAPI backend (Python 3.11+, ChromaDB, OpenAI)
│   ├── question-generator/  # Question generation service (Python 3.11+)
│   ├── web-ui/              # Web interface (Next.js, React, TailwindCSS)
│   └── ios-app/             # iOS app (Swift 6, SwiftUI, iOS 18+) — IN PROGRESS
├── packages/
│   └── shared/              # Shared Python models (Question, QuizSession, Participant)
├── docs/
│   ├── product/             # PRDs, user stories
│   └── research/            # Domain research, competitive analysis, UI reviews
└── course-examples/         # Course materials
```

## Architecture

- **Backend:** FastAPI + in-memory sessions + ChromaDB (semantic search) + SQLite (ratings)
- **AI:** OpenAI for transcription (Whisper), evaluation (GPT-4), TTS
- **iOS:** Native SwiftUI with MVVM + Service Layer, voice-first for driving
- **API contract:** OpenAPI spec as single source of truth (see `.claude/rules/shared.md`)

## Quick Reference

| Task | Command |
|------|---------|
| Start backend | `cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002` |
| Start question-gen | `cd apps/question-generator && uvicorn app.main:app --reload --port 8003` |
| Backend tests | `cd apps/quiz-agent && pytest tests/ -v` |
| Open iOS project | `open apps/ios-app/Hangs/Hangs.xcodeproj` |
| Build iOS (Local) | `cd apps/ios-app/Hangs && xcodebuild -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| iOS tests | `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Install deps | `uv pip install -e apps/quiz-agent && uv pip install -e packages/shared` |

## iOS Schemes

| Scheme | API URL |
|--------|---------|
| Hangs-Local | `http://localhost:8002` |
| Hangs-Prod | `https://quiz-agent-api.fly.dev` |

Models must be Codable and match backend Pydantic models. See `.claude/rules/ios.md` for full iOS guidelines.

## Production

- **URL:** https://quiz-agent-api.fly.dev (Fly.io, 3GB persistent volume)
- **Deploy:** `fly deploy` from `apps/quiz-agent/`

## Task Tracking

Local todo list at `docs/todo/TODO.md`. States: `[ ]` todo · `[~]` wip · `[x]` done. Numbers continue the `docs/issues/issue-NN-*.md` series.

- `/todo` — manage the list (list/add/mark wip/done/edit/remove) via natural language
- `/summarize` — print a copy-pasteable handoff block when ending a session mid-task

Sizable tasks get a plan file at `docs/issues/issue-NN-{slug}.md` linked from the TODO line. At session start, check `docs/todo/TODO.md` for any `[~]` items before deciding what to work on.

## Product & Issue Indices

- `CONTEXT.md` (repo root) — domain glossary. Read before writing PRDs, issue files, or architecture suggestions. Use the canonical terms verbatim.
- `docs/product/INDEX.md` — every PRD with status (Draft / Approved / Shipped / Deferred).
- `docs/issues/INDEX.md` — every issue with `**Triage:**` state (`<category> · <state>`). Issue files carry the line in their header.

## Workflow Skills

- `/to-prd` — synthesize current conversation into a PRD at `docs/product/prds/<slug>.md`. No interview.
- `/triage` — move issues through the state machine (`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `done` / `wontfix`). Updates `docs/issues/INDEX.md`.
- `/diagnose` — disciplined repro → hypothesise → instrument → fix → regression-test loop for hard bugs.
- `/zoom-out` — get a higher-level map of an unfamiliar area in CONTEXT.md vocabulary.
- `/improve-codebase-architecture` — find deepening opportunities; introduces the **module / interface / seam / adapter / depth / leverage / locality** vocabulary in `.claude/skills/improve-codebase-architecture/LANGUAGE.md`.

## Rules

Detailed development workflow, API contracts, testing, and deployment standards are in:
- `.claude/rules/shared.md` — Git workflow, API contracts, testing, security
- `.claude/rules/ios.md` — iOS-specific patterns, build commands, model mapping
- `.claude/rules/backend.md` — Python/FastAPI standards, ChromaDB patterns
