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
| Open iOS project | `open apps/ios-app/CarQuiz/CarQuiz.xcodeproj` |
| Build iOS (Local) | `cd apps/ios-app/CarQuiz && xcodebuild -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| iOS tests | `cd apps/ios-app/CarQuiz && xcodebuild test -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Install deps | `uv pip install -e apps/quiz-agent && uv pip install -e packages/shared` |

## iOS Schemes

| Scheme | API URL |
|--------|---------|
| CarQuiz-Local | `http://localhost:8002` |
| CarQuiz-Prod | `https://quiz-agent-api.fly.dev` |

Models must be Codable and match backend Pydantic models. See `.claude/rules/ios.md` for full iOS guidelines.

## Production

- **URL:** https://quiz-agent-api.fly.dev (Fly.io, 3GB persistent volume)
- **Deploy:** `fly deploy` from `apps/quiz-agent/`

## Rules

Detailed development workflow, API contracts, testing, and deployment standards are in:
- `.claude/rules/shared.md` — Git workflow, API contracts, testing, security
- `.claude/rules/ios.md` — iOS-specific patterns, build commands, model mapping
- `.claude/rules/backend.md` — Python/FastAPI standards, ChromaDB patterns
